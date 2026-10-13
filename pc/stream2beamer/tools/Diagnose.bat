@echo off
rem Diagnose: liest nur, aendert nichts. Ergebnis in Diagnose-Bericht.txt
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Diagnose.ps1" %*
pause
