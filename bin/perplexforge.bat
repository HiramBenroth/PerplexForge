@echo off
rem Standalone PerplexForge launcher.
rem   perplexforge.bat path\to\board.kicad_pcb
rem (You can also drag a .kicad_pcb file onto this script.)

setlocal
set "PF_HOME=%~dp0.."
set "PF_JULIA=julia"
if defined PERPLEXFORGE_JULIA set "PF_JULIA=%PERPLEXFORGE_JULIA%"

if "%~1"=="" (
    echo Usage: perplexforge.bat path\to\board.kicad_pcb
    pause
    exit /b 1
)

"%PF_JULIA%" --project="%PF_HOME%" "%~dp0launch.jl" "%~f1"
if errorlevel 1 pause
endlocal
