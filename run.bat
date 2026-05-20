@echo off
chcp 65001 >nul
cd /d "%~dp0"
echo Working directory: %cd%
start powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0monitor_translation_v2.ps1"