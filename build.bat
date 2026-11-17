@echo off
REM Olympus IDE build script (Windows)
REM Usage: build.bat [run|test|release]

setlocal enabledelayedexpansion
set SRC=src\app
set OUT=bin\olympus.exe

if not exist bin mkdir bin

REM Copy the SDL2 runtime DLL next to the exe (from the active Odin install).
for /f "delims=" %%i in ('odin root') do set "ODIN_ROOT=%%i"
if not exist bin\SDL2.dll copy /Y "!ODIN_ROOT!vendor\sdl2\SDL2.dll" bin\ >nul

if "%1"=="test" (
    odin test src\buffer
    odin test src\input
    goto :eof
)

if "%1"=="release" (
    odin build %SRC% -out:%OUT% -o:speed -no-bounds-check
    goto :eof
)

odin build %SRC% -out:%OUT% -debug
if errorlevel 1 exit /b 1

if "%1"=="run" (
    %OUT%
)
endlocal
