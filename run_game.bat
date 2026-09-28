@echo off
title VoxelCraft
setlocal

rem Locate Godot 4.5.x, in order of preference:
rem   1. %GODOT_EXE%                  - an explicit override
rem   2. Godot.exe beside this script - drop the engine next to the game
rem   3. Godot.exe in a godot\ folder beside this script
set "GODOT=%GODOT_EXE%"
if not defined GODOT if exist "%~dp0Godot.exe" set "GODOT=%~dp0Godot.exe"
if not defined GODOT if exist "%~dp0godot\Godot.exe" set "GODOT=%~dp0godot\Godot.exe"
if not defined GODOT goto :nogodot

echo Starting VoxelCraft...
echo.
"%GODOT%" --accessibility disabled --path "%~dp0."
exit /b %errorlevel%

:nogodot
echo Godot 4.5.x was not found.
echo.
echo Get it from https://godotengine.org/download/windows/ and do one of these:
echo   - rename the .exe to Godot.exe and put it beside this script, or
echo   - put it in a godot\ folder beside this script, or
echo   - set the GODOT_EXE environment variable to its full path.
echo.
echo The project needs the 4.5.x branch, and the export templates only if
echo you want to run build_exe.bat.
echo.
pause
exit /b 1