@echo off
chcp 65001 >nul
cd /d "%~dp0"
if not exist "images" mkdir images
if not exist "data" mkdir data
gpt-image-panel.exe
pause
