# -*- coding: utf-8 -*-
"""生成浮窗演算器的启动器 .bat（纯 ASCII + CRLF，本机 cmd 代码页下才不会乱码）。"""
import io
import os

BAT = (
    "@echo off\r\n"
    "rem FloatCalc - floating exact-arithmetic pad (math_coach parent tool)\r\n"
    "cd /d \"%~dp0\"\r\n"
    "set \"PYEXE=C:\\Users\\Lenovo\\AppData\\Local\\Programs\\Python\\Python310\\pythonw.exe\"\r\n"
    "if not exist \"%PYEXE%\" set \"PYEXE=pythonw\"\r\n"
    "start \"\" \"%PYEXE%\" \"%~dp0app.py\"\r\n"
    "exit /b 0\r\n"
)

here = os.path.dirname(os.path.abspath(__file__))

local = os.path.join(here, "start_float_calc.bat")
with io.open(local, "w", encoding="ascii", newline="") as f:
    f.write(BAT)

# 桌面放一份，起个中文名（文件名可以中文；内容仍保持纯 ASCII）
desktop = os.path.join(os.path.expanduser("~"), "Desktop")
if not os.path.isdir(desktop):
    desktop = os.path.join(os.path.expanduser("~"), "OneDrive", "Desktop")
desk = os.path.join(desktop, "浮窗演算.bat")
with io.open(desk, "wb") as f:
    f.write(BAT.encode("ascii"))

raw = io.open(local, "rb").read()
raw.decode("ascii")  # 解不开就说明掺了非 ASCII，直接炸
assert raw.count(b"\r\n") == 7, raw
print("written:", local)
print("written:", desk)
print("ascii-only, CRLF lines:", raw.count(b"\r\n"))
