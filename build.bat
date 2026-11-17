@echo off
REM Olympus IDE build script (Windows)
REM Usage: build.bat [run|test|release]

setlocal
set SRC=src\app
set OUT=bin\olympus.exe

if not exist bin mkdir bin

if "%1"=="test" (
    REM Run package tests (expand as packages gain *_test.odin files)
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
