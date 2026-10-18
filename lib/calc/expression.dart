/// 算式解析 · 精确求值 · 结果格式化 · 竖式选择。
///
/// 这是「浮窗演算板」（手机/平板）与 PC 端浮窗演算器
/// （tool/floatcalc/engine.py）共用的口径，两边行为必须一致：
///
/// ① **一律用 [Rational] 精确有理数算** —— 0.1+0.2 必须等于 0.3，
///    不能出现 double 误差。家长是拿它验算孩子作业的，错一位数整个工具就废了。
/// ② **竖式只对「一步算式」出** —— 多步算式只给结果。
///    教材里的竖式本来就只有一行运算；把 3+4×5 也排成竖式是杜撰，会教错孩子。
/// ③ **循环小数要检测循环节**，且循环节重复两遍再省略号 ——
///    只写一个数字（0.3…）会被误读成"后面被截断了"。
/// ④ 求值器只做递归下降解析，**不用 eval**（本文件不引入 dart:mirrors，
///    也不拼字符串执行）。
library;

import 'dart:math' as math;

import 'package:math_coach/core/rational.dart';
import 'package:math_coach/typeset/vertical.dart';

/// 用户能看懂的算式错误（除零、不完整、看不懂的字符……）。
class CalcError implements Exception {
  final String message;
  const CalcError(this.message);
  @override
  String toString() => message;
}

/// 一次求值的结果。
class CalcResult {
  final Rational value;

  /// 整条算式恰好是「一个数 运算符 一个数」时记录两侧与运算符，
  /// 供竖式渲染使用；多步算式为 null（不出竖式）。
  final Rational? lhs;
  final Rational? rhs;
  final String? op;

  const CalcResult(this.value, {this.lhs, this.rhs, this.op});

  bool get hasSingleOp => lhs != null && rhs != null && op != null;
}

/// 小数展示形态。
class DecimalForm {
  /// "0.75" / "8" / "8.285714…"（循环小数带省略号）。
  final String text;

  /// 是否是循环小数。
  final bool repeating;

  /// 循环节（非循环小数为空串）。
  final String cycle;

  const DecimalForm(this.text, this.repeating, this.cycle);
}

/// 竖式的两种形态：普通网格 / 长除法"厂"形。
class PadVertical {
  final VerticalLayout? layout;
  final LongDivision? division;
  const PadVertical._({this.layout, this.division});

  /// 按一步算式挑选竖式；挑不出来（多步、小数乘除、结果为负……）返回 null。
  static PadVertical? of(CalcResult r) {
    if (!r.hasSingleOp) return null;
    final a = r.lhs!;
    final b = r.rhs!;
    final op = r.op!;
    final ia = _toInt(a);
    final ib = _toInt(b);

    if (op == '+') {
      if (ia != null && ib != null) return PadVertical._(layout: VerticalTypeset.add(ia, ib));
      return _decimal(a, b, op);
    }
    if (op == '-') {
      if (ia != null && ib != null) {
        if (ia < ib) return null; // 小学竖式不排负数结果，结果行照常给
        return PadVertical._(layout: VerticalTypeset.sub(ia, ib));
      }
      return _decimal(a, b, op);
    }
    if (op == '*') {
      if (ia != null && ib != null) return PadVertical._(layout: VerticalTypeset.mul(ia, ib));
      return null; // 小数乘法竖式要"先按整数算再点小数点"，版面易误导，不出
    }
    if (op == '/') {
      if (ia != null && ib != null && ib != 0) {
        return PadVertical._(division: VerticalTypeset.div(ia, ib));
      }
      return null; // 小数除法同理：先挪除数，不出竖式
    }
    return null; // '^' 与百分号组合不出竖式
  }

  static PadVertical? _decimal(Rational a, Rational b, String op) {
    if (!a.hasFiniteDecimal || !b.hasFiniteDecimal) return null;
    final sa = decimalStringExact(a);
    final sb = decimalStringExact(b);
    if (sa == null || sb == null) return null;
    final res = op == '+' ? a + b : a - b;
    final sr = decimalStringExact(res);
    if (sr == null) return null;

    final maxInt = [sa, sb, sr].map(_intLen).reduce(math.max);
    final maxFrac = [sa, sb, sr].map(_fracLen).reduce(math.max);
    final cols = maxInt + 1 + maxFrac + 1; // 末尾 +1 留给运算符列
    final g = List.generate(3, (_) => List<VCell?>.filled(cols, null));
    _placeDec(g[0], sa, cols, maxFrac);
    final opCol = _leftmost(g[0]) - 1;
    if (opCol < 0) return null;
    g[1][opCol] = VCell(op == '+' ? '+' : '−', VRole.operator);
    _placeDec(g[1], sb, cols, maxFrac);
    _placeDec(g[2], sr, cols, maxFrac);
    return PadVertical._(
      layout: VerticalLayout(
        grid: g,
        rulesAfter: const {1},
        kind: 'decimal_$op',
        steps: [
          '先把小数点对齐，小数位数少的后面补 0。',
          '从末位算起，算完点上小数点。',
          '结果是 $sr。',
        ],
      ),
    );
  }
}

/// 把一条算式求值为精确有理数。
///
/// 支持：整数、小数、分数（3/4）、带分数（2又1/3）、百分号（50%）、
/// + − × ÷ * / ^ ( ) 与全角符号。整条算式恰好是「数 运算符 数」时
/// 记录 [CalcResult.lhs/rhs/op] 供竖式使用。
CalcResult evaluate(String src) {
  final toks = _tokenize(src);
  if (toks.isEmpty) throw const CalcError('请输入算式');
  if (toks.length == 3 &&
      toks[0].kind == 'num' &&
      toks[2].kind == 'num' &&
      _isBinOp(toks[1].text)) {
    final op = toks[1].text;
    final a = toks[0].value!;
    final b = toks[2].value!;
    return CalcResult(_apply(a, b, op), lhs: a, rhs: b, op: op);
  }
  final p = _Parser(toks);
  final v = p.parseExpr();
  p.expectEnd();
  return CalcResult(v);
}

/// 主展示形态：整数 → 原样；有限小数 → 小数；否则 → 循环小数（截断显示）。
DecimalForm decimalForm(Rational v) {
  if (v.isInteger) return DecimalForm(v.n.toString(), false, '');
  if (v.hasFiniteDecimal) return DecimalForm(decimalStringExact(v)!, false, '');
  return _repeating(v);
}

/// 精确小数字符串（仅限有限小数）；非有限小数返回 null。
String? decimalStringExact(Rational v) {
  if (!v.hasFiniteDecimal) return null;
  var d = v.d;
  var c2 = 0;
  var c5 = 0;
  while (d % BigInt.two == BigInt.zero) {
    d ~/= BigInt.two;
    c2++;
  }
  while (d % BigInt.from(5) == BigInt.zero) {
    d ~/= BigInt.from(5);
    c5++;
  }
  final k = math.max(c2, c5);
  final scaled = (v.n * BigInt.from(10).pow(k)) ~/ v.d;
  var s = scaled.abs().toString();
  if (k > 0) {
    while (s.length <= k) {
      s = '0$s';
    }
    s = '${s.substring(0, s.length - k)}.${s.substring(s.length - k)}';
    // 去掉小数末尾无意义的 0（3.50 → 3.5，3.00 → 3）
    s = s.replaceAll(RegExp(r'0+$'), '').replaceAll(RegExp(r'\.$'), '');
  }
  return v.isNegative ? '-$s' : s;
}

// ── 循环小数 ────────────────────────────────────────────────

DecimalForm _repeating(Rational v) {
  final neg = v.isNegative;
  final n = v.n.abs();
  final d = v.d;
  final ip = n ~/ d;
  var rem = n % d;
  final digits = <int>[];
  final seen = <BigInt, int>{};
  var start = digits.length;
  var cycle = '';
  while (rem != BigInt.zero) {
    final k = seen[rem];
    if (k != null) {
      start = k;
      cycle = digits.sublist(k).join();
      break;
    }
    seen[rem] = digits.length;
    rem *= BigInt.from(10);
    digits.add((rem ~/ d).toInt());
    rem %= d;
  }
  if (cycle.isEmpty) {
    // 理论上是有限小数，兜底走分数形式
    return DecimalForm(v.toFractionString(), false, '');
  }
  final pre = digits.sublist(0, start).join();
  // 循环节重复两遍再省略：只写一遍会被误读成"被截断了"
  var show = cycle + cycle;
  if (show.length > 6) show = show.substring(0, 6);
  final text = '${neg ? '-' : ''}$ip.$pre$show…';
  return DecimalForm(text, true, cycle);
}

// ── 词法 ────────────────────────────────────────────────────

class _Tok {
  final String kind; // 'num' | 'op' | 'lp' | 'rp'
  final String text;
  final Rational? value;
  const _Tok(this.kind, this.text, [this.value]);
}

// 全角/异体字符 → ASCII。用转义写，避免肉眼分不清是哪个码位。
const _fullWidth = {
  '\uFF0B': '+', // 全角＋
  '\uFE62': '+', // ﹢
  '\uFF0D': '-', // 全角－
  '\uFE63': '-', // ﹣
  '\u2212': '-', // 数学减号−
  '\u2014': '-', // 破折号—（孩子手打算式常见）
  '\u00D7': '*', // ×
  '\u2715': '*', // ✕
  '\u2716': '*', // ✖
  '\uFF58': '*', // ｘ
  'x': '*',
  'X': '*',
  '\u00F7': '/', // ÷
  '\uFF0F': '/', // ／
  '\u2215': '/', // ∕
  '\uFF0A': '*', // 全角＊
  '\uFF08': '(', // （
  '\uFF09': ')', // ）
  '\u3014': '(', // 〔
  '\u3015': ')', // 〕
  '\uFF1D': '', // ＝
  '=': '',
  '\u3002': '.', // 。
  '\uFF0E': '.', // ．
  '\uFF0C': ',', // ，
  ',': ',',
  '\u3001': ',', // 、
  '\uFF05': '%', // ％
  ' ': '',
  '\t': '',
  '\n': '',
  '\r': '',
};

/// 数字（不含分数线 —— `/` 恒为除号，分数靠除法算出来，
/// 与 PC 端 tool/floatcalc/engine.py 同一口径）。
final _numRe = RegExp(r'(\d+(?:\.\d*)?|\.\d+)');

String _normalize(String src) {
  final buf = StringBuffer();
  for (final ch in src.split('')) {
    final u = ch.codeUnitAt(0);
    // 全角数字 ０-９ → 半角
    if (u >= 0xFF10 && u <= 0xFF19) {
      buf.write(String.fromCharCode(u - 0xFF10 + 0x30));
      continue;
    }
    buf.write(_fullWidth[ch] ?? ch);
  }
  var s = buf.toString();
  // 千分位逗号：27,558 → 27558（Dart 正则没有后视断言，循环到没有相邻数字逗号）
  var prev = '';
  while (prev != s) {
    prev = s;
    s = s.replaceAllMapped(RegExp(r'(\d),(\d)'), (m) => '${m[1]}${m[2]}');
  }
  // 带分数：2又1/3 → (2+1/3)。展开成括号式子，词法层就只用认一种数。
  s = s.replaceAllMapped(
      RegExp(r'(\d+)\s*又\s*(\d+)\s*/\s*(\d+)'), (m) => '(${m[1]}+${m[2]}/${m[3]})');
  // 几分之几：4分之3 → (3/4)（家长口述题型时的说法）
  s = s.replaceAllMapped(
      RegExp(r'(\d+)\s*分之\s*(\d+)'), (m) => '(${m[2]}/${m[1]})');
  return s;
}

List<_Tok> _tokenize(String src) {
  final s = _normalize(src);
  final toks = <_Tok>[];
  var i = 0;
  while (i < s.length) {
    final ch = s[i];
    if (ch == '(') {
      toks.add(const _Tok('lp', '('));
      i++;
      continue;
    }
    if (ch == ')') {
      toks.add(const _Tok('rp', ')'));
      i++;
      continue;
    }
    if ('+-*/^%'.contains(ch)) {
      toks.add(_Tok('op', ch));
      i++;
      continue;
    }
    final nm = _numRe.matchAsPrefix(s, i);
    if (nm != null) {
      var text = nm.group(0)!;
      if (text.endsWith('.')) text = text.substring(0, text.length - 1); // "3." → 3
      final v = Rational.tryParse(text);
      if (v == null) throw const CalcError('数字写法看不懂');
      toks.add(_Tok('num', text, v));
      i = nm.end;
      continue;
    }
    throw CalcError('看不懂这个字符：$ch');
  }
  return toks;
}

bool _isBinOp(String t) => t == '+' || t == '-' || t == '*' || t == '/';

Rational _apply(Rational a, Rational b, String op) {
  switch (op) {
    case '+':
      return a + b;
    case '-':
      return a - b;
    case '*':
      return a * b;
    case '/':
      if (b.isZero) throw const CalcError('除以零');
      return a / b;
    case '^':
      if (!b.isInteger) throw const CalcError('指数必须是整数');
      final e = b.n.toInt();
      if (e.abs() > 64) throw const CalcError('指数太大了，算不动');
      return a.pow(e);
  }
  throw const CalcError('不认识的运算符');
}

// ── 语法（递归下降，不用 eval）────────────────────────────────
//
// 文法与 PC 端 engine.py 一致：
//   expr    := term (('+'|'-') term)*
//   term    := unary (('*'|'/'| 隐式乘) unary)*
//   unary   := ('-'|'+') unary | power
//   power   := postfix ('^' unary)?            # 右结合，指数可以是负数
//   postfix := primary ('%')*
//   primary := NUM | '(' expr ')'

class _Parser {
  final List<_Tok> t;
  int i = 0;
  _Parser(this.t);

  _Tok? get _peek => i < t.length ? t[i] : null;

  void _next() => i++;

  Rational parseExpr() {
    var v = _term();
    while (true) {
      final p = _peek;
      if (p == null || p.kind != 'op') break;
      if (p.text != '+' && p.text != '-') break;
      _next();
      v = _apply(v, _term(), p.text);
    }
    return v;
  }

  Rational _term() {
    var v = _unary();
    while (true) {
      final p = _peek;
      if (p == null) break;
      if (p.kind == 'op' && (p.text == '*' || p.text == '/')) {
        _next();
        v = _apply(v, _unary(), p.text);
      } else if (p.kind == 'num' || p.kind == 'lp') {
        // 隐式乘：2(3+4)、(1+2)(3) —— 家长算面积时常这么写
        v = _apply(v, _unary(), '*');
      } else {
        break;
      }
    }
    return v;
  }

  Rational _unary() {
    final p = _peek;
    if (p != null && p.kind == 'op' && (p.text == '-' || p.text == '+')) {
      _next();
      final v = _unary();
      return p.text == '-' ? -v : v;
    }
    return _power();
  }

  Rational _power() {
    final v = _postfix();
    final p = _peek;
    if (p != null && p.kind == 'op' && p.text == '^') {
      _next();
      return _apply(v, _unary(), '^'); // 右结合
    }
    return v;
  }

  Rational _postfix() {
    var v = _primary();
    while (true) {
      final p = _peek;
      if (p != null && p.kind == 'op' && p.text == '%') {
        _next();
        v = v / Rational(100);
        continue;
      }
      return v;
    }
  }

  Rational _primary() {
    final p = _peek;
    if (p == null) throw const CalcError('算式不完整');
    if (p.kind == 'lp') {
      _next();
      final v = parseExpr();
      final c = _peek;
      if (c == null || c.kind != 'rp') throw const CalcError('括号没有闭合');
      _next();
      return v;
    }
    if (p.kind == 'num') {
      _next();
      return p.value!;
    }
    throw const CalcError('这里应该是个数字');
  }

  void expectEnd() {
    if (i < t.length) throw const CalcError('算式里有看不懂的内容');
  }
}

// ── 竖式小工具 ──────────────────────────────────────────────

int? _toInt(Rational v) =>
    (v.isInteger && v.n.isValidInt && v.n.bitLength < 62) ? v.n.toInt() : null;

int _intLen(String s) {
  final i = s.indexOf('.');
  final body = i < 0 ? s : s.substring(0, i);
  return body.replaceAll('-', '').length;
}

int _fracLen(String s) {
  final i = s.indexOf('.');
  if (i < 0) return 0;
  return s.length - i - 1;
}

/// 把 "12.5" 这样的十进制串右对齐摆进行里：
/// 小数部分占满末尾 [maxFrac] 列（不足补 0），整数部分向左排，
/// 最左侧预留一列给运算符（由调用方填）。
void _placeDec(List<VCell?> row, String s, int cols, int maxFrac) {
  final neg = s.startsWith('-');
  var body = neg ? s.substring(1) : s;
  final dot = body.indexOf('.');
  final intPart = dot < 0 ? body : body.substring(0, dot);
  var fracPart = dot < 0 ? '' : body.substring(dot + 1);
  while (fracPart.length < maxFrac) {
    fracPart = '${fracPart}0';
  }
  var col = cols - 1;
  for (var k = fracPart.length - 1; k >= 0; k--) {
    row[col--] = VCell(fracPart[k], VRole.digit);
  }
  row[col--] = const VCell('.', VRole.digit);
  for (var k = intPart.length - 1; k >= 0; k--) {
    row[col--] = VCell(intPart[k], VRole.digit);
  }
  if (neg && col >= 0) row[col] = const VCell('-', VRole.operator);
}

int _leftmost(List<VCell?> row) {
  for (var c = 0; c < row.length; c++) {
    if (row[c] != null) return c;
  }
  return row.length;
}
