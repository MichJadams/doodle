@echo off
REM Doodle IDE build script (Windows)
REM Usage: build.bat [run [file.odin] | replay [trace] [options] | test | release]
REM   (no args)        debug build -> bin\doodle.exe
REM   run [file.odin]  debug build, then start Doodle (optionally opening a file)
REM   replay [trace]   debug build, then replay a recorded run (default: the last one)
REM                    e.g. build.bat replay last --until 1234   (docs/TRACE.md)
REM   test             run the model + stt unit tests
REM   release          optimized build
REM Debug builds record every run to bin\traces (docs/TRACE.md); release builds don't.

setlocal enabledelayedexpansion
set SRC=src\app
set OUT=bin\doodle.exe

REM Use the default Odin install when `odin` isn't on PATH (e.g. a shell or
REM editor started before PATH was updated).
where odin >nul 2>nul || set "PATH=C:\Odin;%PATH%"

if not exist bin mkdir bin

REM Copy the SDL2 runtime DLL next to the exe (from the active Odin install).
REM NOTE: do not use a variable named ODIN_ROOT here - that name is reserved by
REM the Odin compiler and overriding it breaks `odin build`.
if not exist bin\SDL2.dll (
    for /f "delims=" %%i in ('odin root') do set "ODIN_DIR=%%i"
    copy /Y "!ODIN_DIR!vendor\sdl2\SDL2.dll" bin\ >nul
)

if "%~1"=="test" (
    odin test src\model || exit /b 1
    odin test src\stt
    goto :eof
)

if "%~1"=="release" (
    odin build %SRC% -out:%OUT% -o:speed -no-bounds-check -define:DOODLE_TRACE=false
    goto :eof
)

odin build %SRC% -out:%OUT% -debug
if errorlevel 1 (
    tasklist /FI "IMAGENAME eq doodle.exe" 2>nul | find /I "doodle.exe" >nul && echo Doodle is still running - close it so bin\doodle.exe can be rebuilt.
    exit /b 1
)

if "%~1"=="replay" (
    if "%~2"=="" (
        %OUT% --replay last
    ) else (
        %OUT% --replay %2 %3 %4 %5 %6 %7 %8 %9
    )
)

if "%~1"=="run" (
    if "%~2"=="" (
        %OUT%
    ) else (
        %OUT% "%~2"
    )
)
endlocal
