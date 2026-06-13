@echo off
setlocal
cd /d "%~dp0"

rem ============================================================
rem  Inazuma Mango AW3 -- Get HWID
rem ============================================================
rem
rem  Mostra o HWID desta maquina e consulta o servidor de licenca
rem  (mesmo servidor/HWID do InazumaMango original).
rem
rem  Ordem de tentativa:
rem    1. InazumaMangoAW3.exe --hwid   (modo CLI embutido no .exe)
rem    2. py get_hwid.py / python get_hwid.py (modo dev / sem exe)
rem ============================================================

title Inazuma Mango AW3 -- Get HWID

if exist "InazumaMangoAW3.exe" (
    "InazumaMangoAW3.exe" --hwid
    goto :end
)

where py >nul 2>&1
if %errorlevel%==0 (
    py "get_hwid.py"
    goto :end
)

where python >nul 2>&1
if %errorlevel%==0 (
    python "get_hwid.py"
    goto :end
)

echo [ERROR] Nao foi possivel encontrar InazumaMangoAW3.exe nem o Python (py/python) no PATH.
echo Instale o Python em https://www.python.org/downloads/ ou rode o programa principal uma vez.
pause

:end
endlocal
