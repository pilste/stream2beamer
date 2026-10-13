@echo off
rem stream2beamer ohne Fenster (Einstellungen aus config.json)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0app\Konsole.ps1"
if errorlevel 1 pause
