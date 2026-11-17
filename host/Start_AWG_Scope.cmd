@echo off
setlocal
cd /d "%~dp0"
set "PYTHONPATH=%~dp0tools;%PYTHONPATH%"
if "%~1"=="" (
    py -3 -X utf8 -m awg_gui --shared
) else (
    py -3 -X utf8 -m awg_gui %*
)
if errorlevel 1 pause
endlocal
