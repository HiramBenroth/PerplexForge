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

rem Windows 11 Smart App Control (state 0x1 = on) blocks Julia's compiled package DLLs: run without them
set "PF_FLAGS="
reg query "HKLM\SYSTEM\CurrentControlSet\Control\CI\Policy" /v VerifiedAndReputablePolicyState 2>nul | find "0x1" >nul && set "PF_FLAGS=--pkgimages=no"

"%PF_JULIA%" %PF_FLAGS% --project="%PF_HOME%" "%~dp0launch.jl" "%~f1"
if errorlevel 1 pause
endlocal
