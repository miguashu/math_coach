# -*- coding: utf-8 -*-
"""浮窗演算器（Windows 桌面小工具，家长随手验算用）。

形态：
- 全局热键唤出/隐藏（默认 Ctrl+Alt+Q，可在配置里改）
- 无标题栏、不进任务栏、置顶；弹出即取焦点（热键是用户主动按的，取焦点不算抢）
- 「钉住」后进入点击穿透 + 不抢焦点模式，贴在屏幕一角不挡操作，再按热键解除
- Esc 或焦点移出自动收起（钉住时除外）
- 剪贴板里躺着算式时，唤出即自动带入演算
- 引擎是 engine.py：精确有理数 + 小学竖式，纯本地无网络

用法：
    python app.py                 常驻浮窗
    python app.py --ask "3.6+4.8" 命令行算一个（不开 GUI）
    python app.py --selftest       环境自检（热键/屏幕/引擎）
    python app.py --smoke          开窗 1.2 秒自截屏自退，产出 smoke.png
"""
import ctypes
import io
import json
import os
import queue
import sys
import threading
import time

# ------------------------------------------------------------------ DPI 感知
# 必须在创建任何窗口之前调用；否则 150% 缩放下坐标空间是虚拟的，窗口定位和
# 自截屏全错。放这里（import tkinter 之前）正是为了这一点。

def enable_dpi_awareness():
    if sys.platform != "win32":
        return 1.0
    ok = False
    try:
        if ctypes.windll.user32.SetProcessDpiAwarenessContext(ctypes.c_void_p(-4)):
            ok = True
    except Exception:
        pass
    if not ok:
        try:
            if ctypes.windll.shcore.SetProcessDpiAwareness(2):
                ok = True
        except Exception:
            pass
    if not ok:
        try:
            ctypes.windll.user32.SetProcessDPIAware()
            ok = True
        except Exception:
            pass
    dpi = 0
    try:
        dpi = int(ctypes.windll.user32.GetDpiForSystem())
    except Exception:
        pass
    if dpi <= 0:
        try:
            hdc = ctypes.windll.user32.GetDC(0)
            dpi = int(ctypes.windll.gdi32.GetDeviceCaps(hdc, 88))
            ctypes.windll.user32.ReleaseDC(0, hdc)
        except Exception:
            dpi = 96
    return max(1.0, min(4.0, (dpi or 96) / 96.0))


UI_SCALE = enable_dpi_awareness()

import tkinter as tk
from tkinter import font as tkfont

import engine

HERE = os.path.dirname(os.path.abspath(__file__))
CONFIG = os.path.join(HERE, "floatcalc_config.json")
LOG = os.path.join(HERE, "run.log")
SMOKE_PNG = os.path.join(HERE, "smoke.png")
MUTEX_NAME = "Local\\MathCoachFloatCalc_SingleInstance"

ACCENT = "#2563EB"
DEFAULT_HOTKEY = "Ctrl+Alt+Q"
EMPTY_HINT = "输入即算，不用按回车 · 试试 3.6+4.8 / 58÷7 / 2又1/3+1/2 / 80×50%"


def log(msg):
    line = time.strftime("%Y-%m-%d %H:%M:%S ") + str(msg)
    try:
        with io.open(LOG, "a", encoding="utf-8") as f:
            f.write(line + "\n")
    except Exception:
        pass


# ------------------------------------------------------------------ 配置

def load_config():
    cfg = {
        "x": None, "y": None, "pos_scaled": False,
        "hotkey": DEFAULT_HOTKEY, "opacity": 1.0,
        "clipboard_prefill": True, "history": [],
    }
    try:
        with io.open(CONFIG, "r", encoding="utf-8") as f:
            cfg.update(json.load(f) or {})
    except Exception:
        pass
    return cfg


def save_config(cfg):
    try:
        with io.open(CONFIG, "w", encoding="utf-8") as f:
            json.dump(cfg, f, ensure_ascii=False, indent=1)
    except Exception as e:
        log("save_config failed: %r" % e)


# ------------------------------------------------------------------ 全局热键

WM_HOTKEY = 0x0312
MOD_ALT, MOD_CONTROL, MOD_SHIFT, MOD_WIN, MOD_NOREPEAT = 0x0001, 0x0002, 0x0004, 0x0008, 0x4000
GWL_EXSTYLE = -20
WS_EX_NOACTIVATE, WS_EX_TRANSPARENT, WS_EX_TOOLWINDOW = 0x08000000, 0x00000020, 0x00000080
SWP_NOSIZE, SWP_NOMOVE, SWP_NOZORDER, SWP_FRAMECHANGED = 0x0001, 0x0002, 0x0004, 0x0020


class MSG(ctypes.Structure):
    _fields_ = [("hWnd", ctypes.wintypes.HWND), ("message", ctypes.wintypes.UINT),
                ("wParam", ctypes.wintypes.WPARAM), ("lParam", ctypes.wintypes.LPARAM),
                ("time", ctypes.wintypes.DWORD), ("pt_x", ctypes.c_long), ("pt_y", ctypes.c_long)]


def parse_hotkey(text):
    """'Ctrl+Alt+Q' -> (mod 标志, 虚拟键码)。"""
    mods, vk = 0, None
    for part in str(text).split("+"):
        p = part.strip().lower()
        if p in ("ctrl", "control"):
            mods |= MOD_CONTROL
        elif p == "alt":
            mods |= MOD_ALT
        elif p == "shift":
            mods |= MOD_SHIFT
        elif p in ("win", "meta"):
            mods |= MOD_WIN
        elif len(p) == 1 and p.isalnum():
            vk = ord(p.upper())
        elif p.startswith("f") and p[1:].isdigit() and 1 <= int(p[1:]) <= 24:
            vk = 0x6F + int(p[1:])
        else:
            raise ValueError("热键里有看不懂的键：%r" % part)
    if vk is None:
        raise ValueError("热键里没有一个实际按键：%r" % text)
    return mods | MOD_NOREPEAT, vk


def hotkey_thread(action_q, bindings, failures):
    """独立线程注册并监听热键；只往队列投动作，绝不碰 Tk。"""
    user32 = ctypes.windll.user32
    for hid, mod, vk, action in bindings:
        if not user32.RegisterHotKey(None, hid, mod, vk):
            failures.append(action)
            log("RegisterHotKey failed for %s" % action)
    msg = MSG()
    while True:
        ret = user32.GetMessageW(ctypes.byref(msg), None, 0, 0)
        if ret in (0, -1):
            break
        if msg.message == WM_HOTKEY:
            for b in bindings:
                if b[0] == int(msg.wParam):
                    action_q.put(b[3])


# ------------------------------------------------------------------ 窗口样式

def _hwnd(win):
    return ctypes.windll.user32.GetParent(win.winfo_id()) or win.winfo_id()


def set_ex_style(win, no_activate, transparent):
    user32 = ctypes.windll.user32
    hwnd = _hwnd(win)
    style = user32.GetWindowLongW(hwnd, GWL_EXSTYLE)
    style |= WS_EX_TOOLWINDOW
    if no_activate:
        style |= WS_EX_NOACTIVATE
    else:
        style &= ~WS_EX_NOACTIVATE
    if transparent:
        style |= WS_EX_TRANSPARENT
    else:
        style &= ~WS_EX_TRANSPARENT
    user32.SetWindowLongW(hwnd, GWL_EXSTYLE, style)
    # 关键：改了扩展样式必须跟一次 SetWindowPos + SWP_FRAMECHANGED 才生效，
    # 否则窗口可能根本不重绘（症状：show() 之后窗口像不存在一样）。
    user32.SetWindowPos(hwnd, None, 0, 0, 0, 0,
                        SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_FRAMECHANGED)


# ------------------------------------------------------------------ 单实例

_SINGLETON_MUTEX = None


def acquire_single_instance():
    global _SINGLETON_MUTEX
    if sys.platform != "win32":
        return True
    k32 = ctypes.windll.kernel32
    _SINGLETON_MUTEX = k32.CreateMutexW(None, False, MUTEX_NAME)
    return k32.GetLastError() != 183


# ------------------------------------------------------------------ 主程序

class FloatCalc:
    WIN_W = 408

    def __init__(self, cfg, register_hotkey=True):
        self.cfg = cfg
        self.opacity = float(cfg.get("opacity") or 1.0)
        self.pinned = False
        self._hide_token = None
        self.actions = queue.Queue()
        self.hotkey_failures = []

        self.root = tk.Tk()
        # 注意：不要在创建时 withdraw。实测 withdraw 过的窗口首次 deiconify 不会重绘
        # （症状：show() 之后窗口像不存在，直到桌面偶然重组才露面），而「画过再 withdraw」
        # 的窗口走热键 deiconify 能正常重绘。所以这里保持映射，首帧直接落位。
        self.root.title("floatcalc")
        self.root.overrideredirect(True)
        self.root.attributes("-topmost", True)
        self.root.attributes("-alpha", self.opacity)
        self.root.configure(bg="#FFFFFF")

        s = UI_SCALE
        self.w = int(self.WIN_W * s)
        self.h = int(250 * s)
        self._place_window()          # 先落位，避免首帧闪在默认位置

        self.cjk = self._pick_font(["Microsoft YaHei", "微软雅黑", "SimHei", "SimSun"])
        self.mono = self._pick_font(["Consolas", "Courier New", "NSimSun"])

        self._build()
        self._render_history()
        self._bind_keys()
        self._fit_height()
        self._place_window()          # 高度实测后校正位置（只差几个像素）

        set_ex_style(self.root, no_activate=False, transparent=False)

        if register_hotkey:
            self._start_hotkey()
        self.root.after(80, self._pump)

    # ---------------- 字体 / 定位 ----------------

    def _pick_font(self, candidates):
        try:
            have = set(tkfont.families(self.root))
        except Exception:
            have = set()
        for c in candidates:
            if c in have:
                return c
        return "TkDefaultFont"

    def _place_window(self):
        sw = self.root.winfo_screenwidth()
        sh = self.root.winfo_screenheight()
        s = UI_SCALE
        x, y = self.cfg.get("x"), self.cfg.get("y")
        if x is None or y is None:
            x, y = sw - self.w - int(48 * s), sh - self.h - int(140 * s)
        elif not self.cfg.get("pos_scaled"):
            # 老配置存的是虚拟坐标，折算一次物理坐标并立刻落盘，防重复折算
            x, y = int(x * s), int(y * s)
            self.cfg["pos_scaled"] = True
            save_config(self.cfg)
        x = max(0, min(int(x), sw - self.w))
        y = max(0, min(int(y), sh - self.h))
        self.root.geometry("%dx%d+%d+%d" % (self.w, self.h, x, y))

    # ---------------- 界面 ----------------

    def _build(self):
        s = UI_SCALE
        outer = tk.Frame(self.root, bg="#FFFFFF", highlightbackground="#D7DEE8",
                         highlightthickness=max(1, int(s)))
        outer.pack(fill="both", expand=True)

        bar = tk.Frame(outer, bg=ACCENT, height=int(30 * s))
        bar.pack(fill="x")
        bar.pack_propagate(False)
        tk.Label(bar, text="浮窗演算", bg=ACCENT, fg="#FFFFFF",
                 font=(self.cjk, 11, "bold")).pack(side="left", padx=int(10 * s))
        tk.Label(bar, text="精确有理数 · 竖式", bg=ACCENT, fg="#BFDBFE",
                 font=(self.cjk, 8)).pack(side="left")
        self.pin_btn = tk.Label(bar, text="钉", bg=ACCENT, fg="#FFFFFF",
                                font=(self.cjk, 10, "bold"), cursor="hand2",
                                padx=int(8 * s))
        self.pin_btn.pack(side="right")
        self.pin_btn.bind("<Button-1>", lambda e: self.toggle_pin())
        self.close_btn = tk.Label(bar, text="×", bg=ACCENT, fg="#FFFFFF",
                                  font=(self.cjk, 12, "bold"), cursor="hand2",
                                  padx=int(8 * s))
        self.close_btn.pack(side="right")
        # 关闭 = 隐藏（热键随时唤回），不退出常驻
        self.close_btn.bind("<Button-1>", lambda e: self.hide())
        self._drag_bar = bar
        bar.bind("<Button-1>", self._drag_start)
        bar.bind("<B1-Motion>", self._drag_move)

        body = tk.Frame(outer, bg="#FFFFFF", padx=int(12 * s), pady=int(8 * s))
        body.pack(fill="both", expand=True)

        self.entry = tk.Entry(body, font=(self.mono, 15), relief="flat",
                              highlightbackground="#C7D2E5", highlightcolor=ACCENT,
                              highlightthickness=1, bg="#F8FAFC", fg="#111827",
                              insertbackground=ACCENT)
        self.entry.pack(fill="x", ipady=int(5 * s))
        self.entry.bind("<KeyRelease>", lambda e: self.recompute())

        self.big = tk.Label(body, text="—", bg="#FFFFFF", fg="#111827",
                            font=(self.cjk, 21, "bold"), anchor="w", cursor="hand2")
        self.big.pack(fill="x", pady=(int(8 * s), 0))
        self.big.bind("<Button-1>", lambda e: self._copy_result())

        self.sub = tk.Label(body, text="", bg="#FFFFFF", fg="#6B7280",
                            font=(self.cjk, 9), anchor="w", justify="left")
        self.sub.pack(fill="x")

        self.vtext = tk.Text(body, font=(self.mono, 13), relief="flat", bg="#FFFFFF",
                             fg="#111827", wrap="none", height=1,
                             highlightthickness=0, padx=0, pady=0)
        self.vtext.pack(fill="x", pady=(int(4 * s), 0))
        self.vtext.configure(state="disabled")

        self.note = tk.Label(body, text="", bg="#FFFFFF", fg="#B45309",
                             font=(self.cjk, 9), anchor="w", justify="left")
        self.note.pack(fill="x")

        self.hist = tk.Frame(body, bg="#FFFFFF")
        self.hist.pack(fill="x", pady=(int(6 * s), 0))

        self.hint = tk.Label(body, text="", bg="#FFFFFF", fg="#DC2626",
                             font=(self.cjk, 8), anchor="w", justify="left")
        self.hint.pack(fill="x")

    def _bind_keys(self):
        self.root.bind("<Escape>", lambda e: self.hide())
        self.root.bind("<FocusOut>", self._on_focus_out)
        self.root.bind("<FocusIn>", self._on_focus_in)

    # ---------------- 输入框占位提示 ----------------
    # 占位符不放输入框里：Entry 一聚焦就得清掉，来回切换反而把自己清空了。
    # 示例提示放在输入框下方的副标题行，空态时显示。

    # ---------------- 拖动 ----------------

    def _drag_start(self, e):
        self._ds = (e.x_root, e.y_root, self.root.winfo_x(), self.root.winfo_y())

    def _drag_move(self, e):
        try:
            x0, y0, wx, wy = self._ds
        except AttributeError:
            return
        s = UI_SCALE
        nx, ny = wx + int((e.x_root - x0) * s), wy + int((e.y_root - y0) * s)
        sw, sh = self.root.winfo_screenwidth(), self.root.winfo_screenheight()
        nx = max(0, min(nx, sw - self.w))
        ny = max(0, min(ny, sh - self.h))
        self.root.geometry("+%d+%d" % (nx, ny))
        self.cfg["x"], self.cfg["y"] = nx, ny
        self.cfg["pos_scaled"] = True

    # ---------------- 热键 ----------------

    def _start_hotkey(self):
        try:
            mod, vk = parse_hotkey(self.cfg.get("hotkey") or DEFAULT_HOTKEY)
        except ValueError as e:
            self.hotkey_failures.append(str(e))
            self._show_hotkey_hint()
            return
        t = threading.Thread(target=hotkey_thread,
                             args=(self.actions, [(1, mod, vk, "toggle")], self.hotkey_failures),
                             daemon=True)
        t.start()
        self.root.after(600, self._show_hotkey_hint)

    def _show_hotkey_hint(self):
        if self.hotkey_failures:
            self.hint.configure(text="热键 %s 没注册上（可能被其它软件占用），换一个见配置"
                               % (self.cfg.get("hotkey") or DEFAULT_HOTKEY))

    def _pump(self):
        try:
            while True:
                action = self.actions.get_nowait()
                if action == "toggle":
                    self.toggle()
        except queue.Empty:
            pass
        self.root.after(80, self._pump)

    # ---------------- 显示 / 隐藏 / 钉住 ----------------

    def toggle(self):
        if self.pinned or not self._visible():
            self.show()
        else:
            self.hide()

    def _visible(self):
        try:
            return self.root.state() == "normal" and self.root.winfo_ismapped()
        except Exception:
            return False

    def show(self, prefill=None):
        if self.pinned:
            self.toggle_pin()
        self.root.deiconify()
        self.root.update()                 # 先让窗口真正映射出来
        self.root.lift()
        self.root.attributes("-topmost", True)
        set_ex_style(self.root, no_activate=False, transparent=False)
        self.root.update_idletasks()
        self.root.focus_force()
        self.entry.focus_set()
        if prefill is None and self.cfg.get("clipboard_prefill"):
            prefill = self._clipboard_expression()
        log("show(prefill=%r, cfg_flag=%r)" % (prefill, self.cfg.get("clipboard_prefill")))
        if prefill:
            self.entry.configure(fg="#111827")
            self.entry.delete(0, "end")
            self.entry.insert(0, prefill)
        self.recompute()

    def hide(self):
        if self._hide_token:
            self.root.after_cancel(self._hide_token)
            self._hide_token = None
        self._save_pos()
        self.root.withdraw()

    def _on_focus_out(self, _e):
        if self.pinned or not self._visible():
            return
        self._hide_token = self.root.after(450, self.hide)

    def _on_focus_in(self, _e):
        if self._hide_token:
            self.root.after_cancel(self._hide_token)
            self._hide_token = None

    def toggle_pin(self):
        self.pinned = not self.pinned
        if self.pinned:
            set_ex_style(self.root, no_activate=True, transparent=True)
            self.root.attributes("-alpha", 0.90)
            self.pin_btn.configure(text="已钉", fg="#BFDBFE")
            self.hint.configure(text="已钉住：鼠标可穿透、不挡操作，按 %s 唤出解除"
                               % (self.cfg.get("hotkey") or DEFAULT_HOTKEY))
        else:
            set_ex_style(self.root, no_activate=False, transparent=False)
            self.root.attributes("-alpha", self.opacity)
            self.pin_btn.configure(text="钉", fg="#FFFFFF")
            if "热键" not in self.hint.cget("text"):
                self.hint.configure(text="")
            self.root.update_idletasks()
            self.root.focus_force()
            self.entry.focus_set()

    # ---------------- 剪贴板 ----------------

    def _clipboard_expression(self):
        """剪贴板里是「像算式」的内容才带入，避免把随便一段文字塞进输入框。"""
        try:
            text = self.root.clipboard_get().strip()
        except Exception as e:
            log("clipboard read failed: %r" % e)
            return None
        log("clipboard text: %r" % text)
        if not text or len(text) > 60:
            return None
        if not any(c in text for c in "+-*/×÷^%又"):
            log("clipboard rejected: no operator")
            return None
        allowed = set("0123456789.+-*/×÷()（）^%又，, \t=＝")
        if any(c not in allowed for c in text):
            log("clipboard rejected: bad char")
            return None
        try:
            engine.solve(text)
        except engine.CalcError as e:
            log("clipboard rejected: solve failed %r" % e)
            return None
        return text

    # ---------------- 演算 ----------------

    def recompute(self):
        text = self.entry.get().strip()
        if not text:
            self._render(None)
            return
        try:
            r = engine.solve(text)
        except engine.CalcError as e:
            self._render_error(str(e))
            return
        self._render(r)
        self._remember(r)

    def _render(self, r):
        s = UI_SCALE
        if r is None:
            self.big.configure(text="—", fg="#111827")
            self.sub.configure(text=EMPTY_HINT)
            self._set_vertical(None)
            self.note.configure(text="")
            self._fit_height()
            return
        big = r["fraction"] if r["repeating"] else r["decimal"]
        self.big.configure(text=big, fg="#111827")
        subs = []
        if r["repeating"]:
            subs.append("%s（循环小数）" % r["decimal"])
        if r["mixed"] and r["repeating"]:
            subs.append("= %s" % r["mixed"])
        if r["remainder"]:
            subs.append("= %s" % r["remainder"])
        if not r["repeating"] and not r["remainder"]:
            frac_ctx = any(c in r["expr"] for c in "/又÷%")
            if frac_ctx and r["fraction"] != r["decimal"]:
                subs.append("= %s" % r["fraction"])
        self.sub.configure(text="   ".join(subs))
        self._set_vertical(r["vertical"])
        # 除法的「= q……r」说明与副标题里的商余行重复，只在没有商余行时保留
        note = "" if (r["remainder"] or not r["note"]) else r["note"]
        self.note.configure(text=note)
        self._fit_height()

    def _render_error(self, msg):
        self.big.configure(text="算式有问题", fg="#DC2626")
        self.sub.configure(text=msg, fg="#DC2626")
        self._set_vertical(None)
        self.note.configure(text="")
        self._fit_height()

    def _set_vertical(self, text):
        self.vtext.configure(state="normal")
        self.vtext.delete("1.0", "end")
        if text:
            self.vtext.insert("1.0", text)
        self.vtext.configure(state="disabled")

    def _fit_height(self):
        self.root.update_idletasks()
        need = self.root.winfo_reqheight() + int(4 * UI_SCALE)
        sh = self.root.winfo_screenheight()
        need = max(int(150 * UI_SCALE), min(need, sh - int(16 * UI_SCALE)))
        if need != self.h:
            self.h = need
            self.root.geometry("%dx%d" % (self.w, need))

    # ---------------- 历史 ----------------

    def _remember(self, r):
        hist = self.cfg.get("history") or []
        entry = [r["expr"], r["fraction"] if r["repeating"] else r["decimal"]]
        if hist and hist[0][0] == entry[0]:
            return
        hist.insert(0, entry)
        del hist[20:]
        self.cfg["history"] = hist
        save_config(self.cfg)
        self._render_history()

    def _render_history(self):
        for w in self.hist.winfo_children():
            w.destroy()
        s = UI_SCALE
        for expr, _res in (self.cfg.get("history") or [])[:4]:
            label = expr if len(expr) <= 14 else expr[:13] + "…"
            chip = tk.Label(self.hist, text=label, bg="#EEF2FF", fg="#1E40AF",
                            font=(self.mono, 9), cursor="hand2",
                            padx=int(7 * s), pady=int(2 * s))
            chip.pack(side="left", padx=(0, int(6 * s)))
            chip.bind("<Button-1>", lambda e, t=expr: self._use_history(t))

    def _use_history(self, expr):
        self.entry.configure(fg="#111827")
        self.entry.delete(0, "end")
        self.entry.insert(0, expr)
        self.recompute()

    # ---------------- 复制 ----------------

    def _copy_result(self):
        text = self.big.cget("text")
        if not text or text in ("—", "算式有问题"):
            return
        self.root.clipboard_clear()
        self.root.clipboard_append(text)
        old = self.sub.cget("text")
        self.sub.configure(text="已复制：%s" % text)
        self.root.after(900, lambda: self.sub.configure(text=old))

    # ---------------- 退出 ----------------

    def _save_pos(self):
        self.cfg["x"], self.cfg["y"] = self.root.winfo_x(), self.root.winfo_y()
        self.cfg["pos_scaled"] = True
        save_config(self.cfg)

    def run(self):
        self.root.mainloop()


# ------------------------------------------------------------------ 无头模式

def ask(expr):
    try:
        r = engine.solve(expr)
    except engine.CalcError as e:
        sys.stdout.write("算式有问题：%s\n" % e)
        return 1
    out = io.StringIO()
    out.write("算式  %s\n" % r["expr"])
    out.write("精确  %s\n" % r["fraction"])
    out.write("小数  %s%s\n" % (r["decimal"], "（循环节 %s）" % r["cycle"] if r["repeating"] else ""))
    if r["mixed"]:
        out.write("带分数 %s\n" % r["mixed"])
    if r["remainder"]:
        out.write("商余  %s\n" % r["remainder"])
    if r["vertical"]:
        out.write("\n%s\n" % r["vertical"])
    if r["note"]:
        out.write("\n%s\n" % r["note"])
    sys.stdout.write(out.getvalue())
    return 0


def selftest():
    probe = tk.Tk()
    probe.withdraw()          # 不闪空窗口
    sw, sh = probe.winfo_screenwidth(), probe.winfo_screenheight()
    probe.destroy()
    sys.stdout.write("UI_SCALE=%.2f  screen=%dx%d\n" % (UI_SCALE, sw, sh))
    fails = engine.selftest()
    # 热键注册试用：用一个极不可能被占用的组合，验完立刻注销
    user32 = ctypes.windll.user32
    hid = 0xBFFF
    if user32.RegisterHotKey(None, hid, MOD_CONTROL | MOD_ALT | MOD_NOREPEAT, 0x7B):  # VK_F12
        user32.UnregisterHotKey(None, hid)
        sys.stdout.write("hotkey register: OK\n")
    else:
        sys.stdout.write("hotkey register: FAILED\n")
        fails.append("hotkey register failed")
    if fails:
        for f in fails:
            sys.stdout.write("FAIL: %s\n" % f)
        return 1
    sys.stdout.write("selftest: ALL PASS\n")
    return 0


def smoke():
    if not acquire_single_instance():
        sys.stdout.write("smoke: another instance is running, nothing to do\n")
        return 0
    app = FloatCalc(load_config(), register_hotkey=True)
    app.root.after(300, lambda: app.show("3.6+4.8"))

    def grab():
        app.root.update_idletasks()
        x, y = app.root.winfo_rootx(), app.root.winfo_rooty()
        w, h = app.root.winfo_width(), app.root.winfo_height()
        try:
            from PIL import ImageGrab
            img = ImageGrab.grab(bbox=(x, y, x + w, y + h))
            img.save(SMOKE_PNG)
            sys.stdout.write("smoke: window %dx%d at (%d,%d), grab %s -> %s\n"
                             % (w, h, x, y, img.size, SMOKE_PNG))
            if img.size != (w, h):
                sys.stdout.write("smoke WARN: grab size != window size (DPI mismatch)\n")
        except Exception as e:
            sys.stdout.write("smoke: grab failed %r\n" % e)
        app.root.destroy()

    app.root.after(1400, grab)
    app.run()
    sys.stdout.write("smoke: done\n")
    return 0


def main(argv):
    args = argv[1:]
    if "--ask" in args:
        i = args.index("--ask")
        if i + 1 >= len(args):
            sys.stdout.write("用法：--ask \"算式\"\n")
            return 2
        return ask(args[i + 1])
    if "--selftest" in args:
        return selftest()
    if "--smoke" in args:
        return smoke()

    if not acquire_single_instance():
        ctypes.windll.user32.MessageBoxW(
            None, "浮窗演算器已经在运行了。\n按 Ctrl+Alt+Q 唤出。", "浮窗演算器", 0x40)
        return 0
    cfg = load_config()
    app = FloatCalc(cfg)
    log("floatcalc started (hotkey=%s, scale=%.2f)" % (cfg.get("hotkey"), UI_SCALE))
    # 启动即亮相一次：不然用户双击启动器会以为没反应。
    # 之后焦点移出就自动收起，回到「热键唤出」的常驻形态。
    app.root.after(400, app.show)
    try:
        app.run()
    except Exception as e:
        log("fatal: %r" % e)
        raise
    return 0


if __name__ == "__main__":
    # pythonw 下 sys.stdout/sys.stderr 是 None，直接包 .buffer 会炸，而且没有控制台
    # 看不到报错 —— 启动器走的就是 pythonw，这一行必须防住。
    for _name in ("stdout", "stderr"):
        _s = getattr(sys, _name, None)
        if _s is not None and hasattr(_s, "buffer"):
            try:
                setattr(sys, _name, io.TextIOWrapper(_s.buffer, encoding="utf-8", errors="replace"))
            except Exception:
                pass
    try:
        _code = main(sys.argv)
    except Exception:
        import traceback
        log("fatal:\n" + traceback.format_exc())
        try:
            ctypes.windll.user32.MessageBoxW(
                None, "浮窗演算器启动失败，详情见同目录 run.log", "浮窗演算器", 0x10)
        except Exception:
            pass
        _code = 1
    raise SystemExit(_code)
