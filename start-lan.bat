@echo off
rem Math Coach - 局域网模式：手机（含 iPhone）连同一 WiFi 即可打开
rem 默认的 start.bat 只监听本机；这个脚本监听 0.0.0.0 并把局域网地址打出来
cd /d %~dp0
set DART=D:\workbuddy\flutter\bin\cache\dart-sdk\bin\dart.exe
if not exist "%DART%" set DART=C:\Users\Lenovo\dev\flutter\bin\cache\dart-sdk\bin\dart.exe

if not exist "%DART%" (
  echo Dart not found: %DART%
  pause
  exit /b 1
)

rem 本地 API key 从 .env 读取并注入（源码内不含明文，见 .env.example）
set APIKEY=
if exist ".env" (
  for /f "usebackq tokens=1,* delims==" %%A in (".env") do (
    if "%%A"=="MATH_COACH_API_KEY" set APIKEY=%%B
  )
)
if not defined APIKEY set APIKEY=

echo.
echo  启动后，把下面打出来的 http://192.168.x.x:8787 抄到手机浏览器打开
echo  iPhone 用 Safari：练习 / 错题本 / 复习 / 观感验收 都能看
echo.
"%DART%" run -DMATH_COACH_API_KEY=%APIKEY% bin\serve.dart 8787 --lan
pause
