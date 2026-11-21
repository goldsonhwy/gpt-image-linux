@echo off
chcp 65001 >nul
setlocal
cd /d "%~dp0.."

echo [1/4] 构建前端...
call npm --prefix frontend run build || goto :fail

echo [2/4] 确认 PyInstaller...
if not exist ".venv\Scripts\pyinstaller.exe" (
  .venv\Scripts\python.exe -m pip install pyinstaller || goto :fail
)

echo [3/4] PyInstaller 打包...
if exist "build" rmdir /s /q "build"
if exist "dist\gpt-image-panel" rmdir /s /q "dist\gpt-image-panel"
.venv\Scripts\pyinstaller.exe --noconfirm --clean packaging\gpt-image-panel.spec || goto :fail

echo [4/4] 组装交付包...
set "OUT=dist\gpt-image-panel-win64"
if exist "%OUT%" rmdir /s /q "%OUT%"
mkdir "%OUT%"
xcopy /E /I /Y "dist\gpt-image-panel\*" "%OUT%\" >nul
if not exist "%OUT%\images" mkdir "%OUT%\images"
if not exist "%OUT%\data" mkdir "%OUT%\data"
copy /Y "packaging\run.bat" "%OUT%\run.bat" >nul
copy /Y "packaging\README-二进制版.md" "%OUT%\README.txt" >nul

echo 完成: %cd%\%OUT%
echo 运行: 双击 run.bat 或 gpt-image-panel.exe
exit /b 0

:fail
echo 打包失败，请检查上方错误。
exit /b 1
