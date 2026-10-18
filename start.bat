@echo off
rem Math Coach - start local server and open browser
cd /d %~dp0
rem 工具链 2026-10-16 搬到 D:\workbuddy（C 盘空间不足），旧路径留作兜底。
set DART=D:\workbuddy\flutter\bin\cache\dart-sdk\bin\dart.exe
if not exist "%DART%" set DART=C:\Users\Lenovo\dev\flutter\bin\cache\dart-sdk\bin\dart.exe

if not exist "%DART%" (
  echo Dart not found: %DART%
  pause
  exit /b 1
)

rem --------------------------------------------------------------------------
rem 本地 API key 从 .env 读进来再注入 —— 源码里绝不能出现明文 key。
rem 没配 .env 也能跑（= 空 key），只是 AI 功能要走 App 设置页自己填。
rem --------------------------------------------------------------------------
set APIKEY=
if exist ".env" (
  for /f "usebackq tokens=1,* delims==" %%A in (".env") do (
    if "%%A"=="MATH_COACH_API_KEY" set APIKEY=%%B
  )
)
if not defined APIKEY set APIKEY=

start "MathCoach Server" /min "%DART%" -DMATH_COACH_API_KEY=%APIKEY% bin\serve.dart 8787
timeout /t 2 /nobreak >nul
start "" http://127.0.0.1:8787

echo.
echo  Server is running in the minimized window.
echo  Browser should open at http://127.0.0.1:8787
echo  To stop: close the minimized "MathCoach Server" window.
echo.
pause
