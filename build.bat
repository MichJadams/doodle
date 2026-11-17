@echo off
REM Doodle IDE build script (Windows)
REM Usage: build.bat [run|test|release]

setlocal enabledelayedexpansion
set SRC=src\app
set OUT=bin\doodle.exe

if not exist bin mkdir bin

REM Copy the SDL2 runtime DLL next to the exe (from the active Odin install).
REM NOTE: do not use a variable named ODIN_ROOT here - that name is reserved by
REM the Odin compiler and overriding it breaks `odin build`.
if not exist bin\SDL2.dll (
    for /f "delims=" %%i in ('odin root') do set "ODIN_DIR=%%i"
    copy /Y "!ODIN_DIR!vendor\sdl2\SDL2.dll" bin\ >nul
)

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
