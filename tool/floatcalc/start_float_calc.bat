@echo off
rem FloatCalc - floating exact-arithmetic pad (math_coach parent tool)
cd /d "%~dp0"
set "PYEXE=C:\Users\Lenovo\AppData\Local\Programs\Python\Python310\pythonw.exe"
if not exist "%PYEXE%" set "PYEXE=pythonw"
start "" "%PYEXE%" "%~dp0app.py"
exit /b 0
