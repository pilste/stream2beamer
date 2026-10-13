@echo off
rem Startet die Bedienoberflaeche von stream2beamer
start "" powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0app\Gui.ps1"
