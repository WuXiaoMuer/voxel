@echo off
title VoxelCraft Build
setlocal

rem Locate Godot 4.5.x, in order of preference:
rem   1. %GODOT_EXE%                  - an explicit override
rem   2. Godot.exe beside this script - drop the engine next to the game
rem   3. Godot.exe in a godot\ folder beside this script
set "GODOT=%GODOT_EXE%"
if not defined GODOT if exist "%~dp0Godot.exe" set "GODOT=%~dp0Godot.exe"
if not defined GODOT if exist "%~dp0godot\Godot.exe" set "GODOT=%~dp0godot\Godot.exe"
if not defined GODOT goto :nogodot

echo Building VoxelCraft.exe ...
echo.
if not exist "%~dp0build" mkdir "%~dp0build"
if exist "%~dp0build\VoxelCraft.exe" del /q "%~dp0build\VoxelCraft.exe"
"%GODOT%" --accessibility disabled --headless --path "%~dp0." --export-release "Windows Desktop" "%~dp0build\VoxelCraft.exe"
echo.
if exist "%~dp0build\VoxelCraft.exe" (echo Done - build\VoxelCraft.exe) else (echo FAILED - see the errors above)
pause
exit /b %errorlevel%

:nogodot
echo Godot 4.5.x was not found.
echo.
echo Get it from https://godotengine.org/download/windows/ and do one of these:
echo   - rename the .exe to Godot.exe and put it beside this script, or
echo   - put it in a godot\ folder beside this script, or
echo   - set the GODOT_EXE environment variable to its full path.
echo.
echo The export also needs the 4.5.x export templates installed
echo (Editor -^> Manage Export Templates).
echo.
pause
exit /b 1