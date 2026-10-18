# -*- coding: utf-8 -*-
"""浮窗演算引擎：精确有理数运算 + 小学竖式排版。

口径与 math_coach 内核保持一致：
- 所有运算走 fractions.Fraction 精确有理数，0.1 + 0.2 必须等于 0.3，不吞浮点误差；
- 竖式只对「一步算式」（两个数字字面量的 + - × ÷）展示，多步算式只给结果，
  不假装有竖式 —— 骗人的过程比没有过程更糟；
- 纯本地、无网络、无模型，毫秒级。

单独运行本文件即执行自检：  python engine.py
"""
from fractions import Fraction
import re

__all__ = [
    "CalcError", "normalize", "parse", "evaluate", "solve",
    "fraction_str", "mixed_str", "decimal_str", "selftest",
]


class CalcError(Exception):
    """算式不合法：语法错误、除零、指数非整数等。"""


# ---------------------------------------------------------------- 归一化

_FULLWIDTH = {
    "＋": "+", "﹢": "+", "－": "-", "﹣": "-", "−": "-",
    "×": "*", "✕": "*", "✖": "*",
    "÷": "/", "／": "/", "∕": "/",
    "（": "(", "）": ")", "〔": "(", "〕": ")",
    "＝": "=", "。": ".", "．": ".", "，": ",", "、": ",",
    "％": "%", "　": " ", " ": " ",
    "０": "0", "１": "1", "２": "2", "３": "3", "４": "4",
    "５": "5", "６": "6", "７": "7", "８": "8", "９": "9",
}
_TABLE = str.maketrans(_FULLWIDTH)


def normalize(s):
    """全角转半角、去千分位、展开带分数与「几分之几」、去掉等号与空白。"""
    s = str(s).translate(_TABLE)
    s = re.sub(r"(?<=\d),(?=\d)", "", s)                 # 27,558 -> 27558
    s = re.sub(r"(\d+)\s*又\s*(\d+)\s*/\s*(\d+)", r"(\1+\2/\3)", s)   # 2又1/2
    s = re.sub(r"(\d+)\s*分之\s*(\d+)", r"(\2/\1)", s)                # 2分之1 -> 1/2
    s = s.replace("=", "").replace(" ", "")
    if not s:
        raise CalcError("空算式")
    return s


# ---------------------------------------------------------------- 词法

_TOK_RE = re.compile(r"(?P<num>\d+\.\d*|\.\d+|\d+)|(?P<op>[+\-*/^%])|(?P<lp>\()|(?P<rp>\))")


def tokenize(s):
    toks, pos = [], 0
    while pos < len(s):
        m = _TOK_RE.match(s, pos)
        if not m:
            raise CalcError("看不懂这个字符：%r" % s[pos:pos + 6])
        if m.group("num") is not None:
            toks.append(("num", Fraction(m.group("num"))))
        elif m.group("lp"):
            toks.append(("(", None))
        elif m.group("rp"):
            toks.append((")", None))
        else:
            toks.append((m.group("op"), None))
        pos = m.end()
    return toks


# ---------------------------------------------------------------- 语法（递归下降）

class _Parser:
    """expr := term (('+'|'-') term)*
    term := unary (('*'|'/'| 隐式乘) unary)*
    unary := ('-'|'+') unary | power
    power := postfix ('^' unary)?          # 右结合
    postfix := primary ('%')*
    primary := NUM | '(' expr ')'
    """

    def __init__(self, toks):
        self.toks = toks
        self.i = 0

    def peek(self):
        return self.toks[self.i][0] if self.i < len(self.toks) else None

    def next(self):
        t = self.toks[self.i]
        self.i += 1
        return t

    def expr(self):
        node = self.term()
        while self.peek() in ("+", "-"):
            op = self.next()[0]
            node = ("bin", op, node, self.term())
        return node

    def term(self):
        node = self.unary()
        while True:
            t = self.peek()
            if t in ("*", "/"):
                op = self.next()[0]
                node = ("bin", op, node, self.unary())
            elif t in ("num", "("):          # 2(3+4)、(1+2)(3) 视作乘法
                node = ("bin", "*", node, self.unary())
            else:
                return node

    def unary(self):
        if self.peek() in ("+", "-"):
            op = self.next()[0]
            inner = self.unary()
            return inner if op == "+" else ("neg", inner)
        return self.power()

    def power(self):
        base = self.postfix()
        if self.peek() == "^":
            self.next()
            return ("bin", "^", base, self.unary())   # 右结合
        return base

    def postfix(self):
        node = self.primary()
        while self.peek() == "%":
            self.next()
            node = ("pct", node)
        return node

    def primary(self):
        t = self.peek()
        if t == "num":
            return ("num", self.next()[1])
        if t == "(":
            self.next()
            node = self.expr()
            if self.peek() != ")":
                raise CalcError("括号没闭合")
            self.next()
            return node
        if t is None:
            raise CalcError("算式不完整")
        raise CalcError("这里不该出现 %r" % t)

    def expect_end(self):
        if self.i != len(self.toks):
            raise CalcError("算式后面有多余的内容：%r" % (self.toks[self.i:],))


def parse(s):
    """解析成 AST（不校验是否到结尾，仅供 inspect）。"""
    p = _Parser(tokenize(normalize(s)))
    return p.expr()


def parse_full(s):
    """解析并确认整个字符串被消费完。"""
    p = _Parser(tokenize(normalize(s)))
    node = p.expr()
    p.expect_end()
    return node


# ---------------------------------------------------------------- 求值

def evaluate(node):
    tag = node[0]
    if tag == "num":
        return node[1]
    if tag == "neg":
        return -evaluate(node[1])
    if tag == "pct":
        return evaluate(node[1]) / 100
    op = node[1]
    a, b = evaluate(node[2]), evaluate(node[3])
    if op == "+":
        return a + b
    if op == "-":
        return a - b
    if op == "*":
        return a * b
    if op == "/":
        if b == 0:
            raise CalcError("除数不能是 0")
        return a / b
    if op == "^":
        if b.denominator != 1:
            raise CalcError("指数只能是整数（小学范围）")
        e = int(b)
        if a == 0 and e < 0:
            raise CalcError("0 的负数次方没有意义")
        return a ** e
    raise CalcError("不认识的运算 %r" % op)


# ---------------------------------------------------------------- 数值格式化

def _is_terminating(fr):
    """小数是否有限（分母只含 2 和 5）。"""
    d = fr.denominator
    while d % 2 == 0:
        d //= 2
    while d % 5 == 0:
        d //= 5
    return d == 1


def _decimal_places(fr):
    """有限小数的小数位数（调用前须确认有限）。"""
    d = fr.denominator
    a = b = 0
    while d % 2 == 0:
        d //= 2
        a += 1
    while d % 5 == 0:
        d //= 5
        b += 1
    return max(a, b)


def decimal_str(fr, max_cycle=6):
    """返回 (文本, 是否循环, 循环节)。有限小数给精确值；循环小数给 前缀+一个循环节+…。"""
    sign = "-" if fr < 0 else ""
    fr = -fr if fr < 0 else fr
    ip, fp = divmod(fr.numerator, fr.denominator)
    if fp == 0:
        return ("%s%d" % (sign, ip), False, "")
    if _is_terminating(fr):
        k = _decimal_places(fr)
        scaled = fr.numerator * 10 ** k // fr.denominator
        s = str(scaled).rjust(k + 1, "0")
        return ("%s%s.%s" % (sign, s[:-k], s[-k:]), False, "")
    rem, seen, digits = fp, {}, []
    while rem != 0 and rem not in seen:
        seen[rem] = len(digits)
        rem *= 10
        digits.append(rem // fr.denominator)
        rem %= fr.denominator
    start = seen.get(rem, len(digits))
    pre = "".join(str(d) for d in digits[:start])
    cyc = "".join(str(d) for d in digits[start:])
    if len(cyc) <= 2:
        show = cyc * 2          # 短循环节重复一遍，读起来才像循环而不是截断
    elif len(cyc) <= max_cycle:
        show = cyc
    else:
        show = cyc[:max_cycle]
    return ("%s%d.%s%s…" % (sign, ip, pre, show), True, cyc)


def fraction_str(fr):
    if fr.denominator == 1:
        return str(fr.numerator)
    return "%d/%d" % (fr.numerator, fr.denominator)


def mixed_str(fr):
    """假分数转带分数（3/2 -> 1又1/2）；真分数与整数返回 None。"""
    if fr.denominator == 1:
        return None
    a = -fr if fr < 0 else fr
    whole = a.numerator // a.denominator
    if whole == 0:
        return None
    rem = a - whole
    sign = "-" if fr < 0 else ""
    if rem == 0:
        return "%s%d" % (sign, whole)
    return "%s%d又%d/%d" % (sign, whole, rem.numerator, rem.denominator)


def remainder_str(a, b):
    """整数除法的商……余数；整除返回 None。"""
    q, r = divmod(a, b)
    if r == 0:
        return None
    return "%d……%d" % (q, r)


# ---------------------------------------------------------------- 竖式

def _int_frac_parts(fr):
    """非负有限小数 -> (整数位串, 小数位串)；否则 None。"""
    if fr < 0 or not _is_terminating(fr):
        return None
    ip, fp = divmod(fr.numerator, fr.denominator)
    if fp == 0:
        return (str(ip), "")
    k = _decimal_places(fr)
    scaled = fr.numerator * 10 ** k // fr.denominator
    s = str(scaled).rjust(k + 1, "0")
    return (s[:-k], s[-k:])


def vertical_add_sub(a, b, op):
    """加减竖式：小数点对齐（小学口径）。"""
    pa, pb = _int_frac_parts(a), _int_frac_parts(b)
    if pa is None or pb is None:
        return None, None
    res = a + b if op == "+" else a - b
    neg = res < 0
    pr = _int_frac_parts(-res if neg else res)
    if pr is None:
        return None, None
    iw = max(len(pa[0]), len(pb[0]), len(pr[0]))
    fw = max(len(pa[1]), len(pb[1]), len(pr[1]))
    opw = 2

    def pad(parts):
        i, f = parts
        return i.rjust(iw) + ("." + f.ljust(fw) if fw else "")

    w = opw + iw + (1 + fw if fw else 0)
    rows = [(" " * opw + pad(pa)).rstrip(),
            ((op + " ").ljust(opw) + pad(pb)).rstrip(),
            "-" * w,
            (("-" if neg else " ") + " " + pad(pr)).rstrip()]
    return "\n".join(rows), None


def vertical_mul(a, b):
    """乘法竖式：部分积逐行；带小数时附「共几位小数、从右起数几位点小数点」说明。"""
    pa, pb = _int_frac_parts(a), _int_frac_parts(b)
    if pa is None or pb is None:
        return None, None
    ka, kb = len(pa[1]), len(pb[1])
    A = int(pa[0] + pa[1]) if (pa[0] + pa[1]) else 0
    B = int(pb[0] + pb[1]) if (pb[0] + pb[1]) else 0
    if A >= 10 ** 7 or B >= 10 ** 5:
        return None, None
    sa, sb = str(A), str(B)
    prod = A * B
    w = len(str(prod))
    rows = [sa.rjust(w), "×" + sb.rjust(w - 1), "-" * w]
    for j, ch in enumerate(reversed(sb)):
        rows.append(str(A * int(ch)).rjust(w - j))
    rows.append("-" * w)
    rows.append(str(prod).rjust(w))
    note = None
    k = ka + kb
    if k:
        s = str(prod).rjust(k + 1, "0")
        shown = s[:-k] + "." + s[-k:]
        note = "两个因数一共 %d 位小数，积从右边起数出 %d 位点上小数点 → %s" % (k, k, shown)
    return "\n".join(rows), note


def vertical_div(a, b):
    """除法竖式（长除法，整数）：商写在被除数上方，逐步乘积/余数。"""
    if a.denominator != 1 or b.denominator != 1:
        return None, None
    A, B = int(a), int(b)
    if B <= 0 or A < 0 or A >= 10 ** 8 or B >= 10 ** 4:
        return None, None
    digits = [int(c) for c in str(A)]
    n = len(digits)
    prefix = "%d)" % B
    q = [" "] * n
    steps = []
    cur = 0
    for i, d in enumerate(digits):
        cur = cur * 10 + d
        if cur >= B:
            qd = cur // B
            q[i] = str(qd)
            prod = qd * B
            steps.append((i, prod, cur - prod))
            cur -= prod
    if not steps:
        q[n - 1] = "0"                      # 被除数小于除数：商 0
    rows = [" " * len(prefix) + "".join(q).rstrip(),
            " " * len(prefix) + "-" * n,
            prefix + "".join(str(d) for d in digits)]
    for i, prod, rem in steps:
        rows.append(" " * len(prefix) + str(prod).rjust(i + 1))
        rows.append(" " * len(prefix) + "-" * (i + 1))
        if rem:
            rows.append(" " * len(prefix) + str(rem).rjust(i + 1))
    qval, r = divmod(A, B)
    note = ("正好整除" if r == 0 else "= %d……%d（余数 %d）" % (qval, r, r))
    return "\n".join(rows), note


# ---------------------------------------------------------------- 一步算式识别

def one_step(node):
    """整体就是一个「数字 op 数字」时返回 (op, a, b)，否则 None。"""
    if node[0] == "bin" and node[1] in "+-*/" \
            and node[2][0] == "num" and node[3][0] == "num":
        return (node[1], node[2][1], node[3][1])
    return None


# ---------------------------------------------------------------- 对外主入口

def solve(text):
    """算一个算式，返回结构化结果（含竖式与说明）。"""
    node = parse_full(text)
    val = evaluate(node)
    dec, rep, cyc = decimal_str(val)
    out = {
        "expr": str(text).strip(),
        "value": val,
        "fraction": fraction_str(val),
        "decimal": dec,
        "repeating": rep,
        "cycle": cyc,
        "mixed": mixed_str(val),
        "vertical": None,
        "note": None,
        "remainder": None,
    }
    step = one_step(node)
    if step:
        op, a, b = step
        if op in "+-":
            out["vertical"], out["note"] = vertical_add_sub(a, b, op)
        elif op == "*":
            out["vertical"], out["note"] = vertical_mul(a, b)
        else:
            out["vertical"], out["note"] = vertical_div(a, b)
            if a.denominator == 1 and b.denominator == 1 and b != 0:
                out["remainder"] = remainder_str(a, b)
    return out


# ---------------------------------------------------------------- 自检

def selftest():
    """无头自检：返回 (失败信息列表)。空列表 = 全过。"""
    fails = []

    def eq(got, want, label):
        if got != want:
            fails.append("%s: got %r want %r" % (label, got, want))

    def ok(cond, label):
        if not cond:
            fails.append(label)

    # --- 归一化与解析 ---
    eq(normalize("３.６＋４.８"), "3.6+4.8", "fullwidth digits/ops")
    eq(normalize("27,558+1"), "27558+1", "thousands separator")
    eq(normalize("2又1/2+1"), "(2+1/2)+1", "mixed number")
    eq(normalize("2分之1+1"), "(1/2)+1", "fen zhi")

    # --- 精确有理数（浮点会错的地方） ---
    eq(fraction_str(evaluate(parse("0.1+0.2"))), "3/10", "0.1+0.2 exact")
    eq(evaluate(parse("0.1+0.2")), Fraction(3, 10), "0.1+0.2 fraction value")
    eq(fraction_str(evaluate(parse("1/3+1/6"))), "1/2", "1/3+1/6")
    eq(fraction_str(evaluate(parse("2/3×3/4"))), "1/2", "fraction mul")
    eq(fraction_str(evaluate(parse("7÷2"))), "7/2", "7/2 stays exact")

    # --- 运算优先级 / 括号 / 负号 / 幂 ---
    eq(evaluate(parse("2+3×4")), Fraction(14), "precedence")
    eq(evaluate(parse("(2+3)×4")), Fraction(20), "parens")
    eq(evaluate(parse("2(3+4)")), Fraction(14), "implicit mul")
    eq(evaluate(parse("(1+2)(3)")), Fraction(9), "implicit mul parens")
    eq(evaluate(parse("-3+5")), Fraction(2), "unary minus")
    eq(evaluate(parse("3×-2")), Fraction(-6), "minus after op")
    eq(evaluate(parse("2^3^2")), Fraction(512), "power right assoc")
    eq(evaluate(parse("2^-2")), Fraction(1, 4), "negative power")
    eq(evaluate(parse("50%")), Fraction(1, 2), "percent")
    eq(evaluate(parse("80×50%")), Fraction(40), "percent in expr")
    eq(evaluate(parse("1.5×2")), Fraction(3), "decimal mul")

    # --- 错误 ---
    for bad, why in [("1/0", "div zero"), ("2^(1/2)", "frac power"),
                     ("(1+2", "unclosed paren"), ("3 $ 4", "bad char")]:
        try:
            evaluate(parse(bad))
            fails.append("should raise: %s (%s)" % (bad, why))
        except CalcError:
            pass

    # --- 小数格式化 ---
    eq(decimal_str(Fraction(3, 10)), ("0.3", False, ""), "terminating decimal")
    eq(decimal_str(Fraction(1, 8)), ("0.125", False, ""), "1/8")
    eq(decimal_str(Fraction(1, 3))[0], "0.33…", "1/3 repeating text")
    ok(decimal_str(Fraction(1, 3))[1] and decimal_str(Fraction(1, 3))[2] == "3", "1/3 cycle")
    eq(decimal_str(Fraction(1, 7))[2], "142857", "1/7 cycle")
    eq(decimal_str(Fraction(1, 6))[0], "0.166…", "1/6 repeating text")
    eq(decimal_str(Fraction(5))[0], "5", "integer decimal")
    eq(mixed_str(Fraction(3, 2)), "1又1/2", "mixed number display")
    eq(mixed_str(Fraction(1, 2)), None, "proper fraction no mixed")
    eq(mixed_str(Fraction(5, 2)), "2又1/2", "improper fraction")
    eq(mixed_str(Fraction(4, 2)), None, "integer has no mixed form")

    # --- 竖式：加减小数点对齐 ---
    v, _ = vertical_add_sub(Fraction(36, 10), Fraction(48, 10), "+")
    eq(v, "  3.6\n+ 4.8\n-----\n  8.4", "add vertical 3.6+4.8")
    v, _ = vertical_add_sub(Fraction(125, 10), Fraction(375, 100), "+")
    eq(v, "  12.5\n+  3.75\n-------\n  16.25", "add vertical align frac")
    v, _ = vertical_add_sub(Fraction(123), Fraction(45), "+")
    eq(v, "  123\n+  45\n-----\n  168", "add vertical ints")
    v, _ = vertical_add_sub(Fraction(3), Fraction(8), "-")
    eq(v, "  3\n- 8\n---\n- 5", "sub negative result sign")
    ok(vertical_add_sub(Fraction(1, 3), Fraction(1, 6), "+")[0] is None, "no vertical for fractions")

    # --- 竖式：乘法部分积 ---
    v, note = vertical_mul(Fraction(123), Fraction(45))
    eq(v, " 123\n× 45\n----\n 615\n492\n----\n5535", "mul vertical 123x45")
    ok(note is None, "no decimal note for ints")
    v, note = vertical_mul(Fraction(36, 10), Fraction(48, 10))
    ok("2 位小数" in note and "17.28" in note, "mul decimal note")

    # --- 竖式：长除法 ---
    v, note = vertical_div(Fraction(58), Fraction(7))
    eq(v, "   8\n  --\n7)58\n  56\n  --\n   2", "div vertical 58/7")
    ok("8……2" in note, "div remainder note")
    v, note = vertical_div(Fraction(144), Fraction(12))
    ok(v.splitlines()[0].strip() == "12", "div vertical quotient 12")
    ok(note == "正好整除", "exact division note")
    ok(vertical_div(Fraction(3), Fraction(4))[0] is not None, "div a<b still lays out")
    ok(vertical_div(Fraction(1, 2), Fraction(4))[0] is None, "no long div for fractions")

    # --- solve 汇总 ---
    r = solve("3.6+4.8")
    eq(r["decimal"], "8.4", "solve decimal")
    ok(r["vertical"] is not None, "solve vertical present")
    r = solve("58÷7")
    eq(r["remainder"], "8……2", "solve remainder")
    eq(r["decimal"], "8.285714…", "solve 58/7 decimal")
    r = solve("2×(3+4)")
    ok(r["vertical"] is None, "multi-step: no fake vertical")
    eq(r["decimal"], "14", "multi-step result")
    r = solve("2又1/3+1/2")
    eq(r["fraction"], "17/6", "mixed solve fraction")
    eq(r["mixed"], "2又5/6", "mixed solve mixed")

    return fails


if __name__ == "__main__":
    _fails = selftest()
    for _f in _fails:
        print("FAIL:", _f)
    print("engine selftest: %s (%d failed)" % ("ALL PASS" if not _fails else "FAILED", len(_fails)))
    raise SystemExit(1 if _fails else 0)
