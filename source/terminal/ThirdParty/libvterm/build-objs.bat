@echo off
rem ===========================================================================
rem  build-objs.bat - Compile vendored libvterm C sources to linkable objects
rem ---------------------------------------------------------------------------
rem  Demand #24 (ESP-024 / ADR-024-02): libvterm is embedded into the Terminal
rem  BPL via {$L} object-file linking - no separate DLL.
rem
rem  TWO PLATFORMS, TWO COMPILERS, AND THEY ARE NOT INTERCHANGEABLE.
rem
rem    Win32   bcc32c.exe  (bin)    -> 32-bit OMF   -> obj\*.obj
rem    Win64x  bcc64x.exe  (bin64)  -> COFF x64     -> obj\Win64x\*.o
rem
rem  Each platform's Delphi linker REJECTS the other's object outright, with
rem  "E2045 Bad object file format" - which reads like a corrupt file and is
rem  really the wrong architecture. Hence separate output folders: a build can
rem  never pick up the wrong one, whoever ran last.
rem
rem  The legacy bcc32.exe is C89/C++03 and CANNOT compile libvterm (C99
rem  designated initializers + mixed declarations). bcc32c and bcc64x are the
rem  Clang-based compilers and both handle it.
rem
rem  Usage:  build-objs.bat            (Win32, the default)
rem          build-objs.bat Win64x     (Win64 Modern, for the 64-bit IDE)
rem    Requires the compiler on PATH, or the BDS environment variable pointing
rem    at the RAD Studio root (set by rsvars.bat / inside the IDE).
rem
rem  Unity build: libvterm_unity bundles all 9 translation units into ONE object
rem  to solve circular cross-references that Delphi's single-pass {$L} linker
rem  cannot resolve from separately-linked objects.
rem ===========================================================================
setlocal

set HERE=%~dp0
set PLATFORM=%~1
if "%PLATFORM%"=="" set PLATFORM=Win32

rem -- Locate the compiler and decide where the objects land -------------------
if /I "%PLATFORM%"=="Win64x" goto :win64
if /I "%PLATFORM%"=="Win32" goto :win32
echo *** Unknown platform "%PLATFORM%" - expected Win32 or Win64x ***
endlocal & exit /b 1

:win32
set OUTDIR=%HERE%obj
set OBJEXT=obj
set BCC=bcc32c.exe
if defined BDS if exist "%BDS%\bin\bcc32c.exe" set BCC="%BDS%\bin\bcc32c.exe"
goto :compile

:win64
set OUTDIR=%HERE%obj\Win64x
set OBJEXT=o
set BCC=bcc64x.exe
if defined BDS if exist "%BDS%\bin64\bcc64x.exe" set BCC="%BDS%\bin64\bcc64x.exe"
goto :compile

:compile
rem -- Core translation units (see CODE-MAP for the role of each) --------------
set UNITS=encoding keyboard mouse parser pen screen state unicode vterm

if not exist "%OUTDIR%" mkdir "%OUTDIR%"

set FAILED=0
for %%U in (%UNITS%) do (
  echo Compiling %%U.c [%PLATFORM%]
  %BCC% -c -I"%HERE%include" -I"%HERE%src" -o"%OUTDIR%\%%U.%OBJEXT%" "%HERE%src\%%U.c"
  if errorlevel 1 set FAILED=1
)

if "%FAILED%"=="1" (
  echo.
  echo *** libvterm individual objects build FAILED [%PLATFORM%] ***
  endlocal & exit /b 1
)

rem -- Unity build (all 9 TUs in one object for Delphi {$L} linking) -----------
echo Compiling libvterm_unity.c [%PLATFORM%]
%BCC% -c -I"%HERE%include" -I"%HERE%src" -o"%OUTDIR%\libvterm_unity.%OBJEXT%" "%HERE%src\libvterm_unity.c"
if errorlevel 1 (
  echo.
  echo *** libvterm unity build FAILED [%PLATFORM%] ***
  endlocal & exit /b 1
)

echo.
echo libvterm objects built into %OUTDIR%
endlocal & exit /b 0
