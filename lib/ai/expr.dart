/// 小学四则运算表达式求值器 —— 给「模型答案本地验算」用。
///
/// 铁律落地处之一：讲解 Agent 给出 `equation`（如 "(150-100)*2"），
/// 这里用 Rational 精确算出来，和模型报的答案对不上就打回重做。
/// 支持：+ - * / × ÷ ( )、小数、负号。除不尽时保留分数值参与后续运算，
/// 最终结果转 double 比较（容差 1e-9 相对误差）。
library;

import '../core/rational.dart';

class ExprEval {
  /// 求值失败返回 null（不是合法四则式就不硬算）。
  ///
  /// 容忍 `237 + 158 = 395` 这种写法：实测模型写验算式时**每次都会顺手把答案带上**
  /// （三道题全带，因为人类写算式就是这么写的）。早先版本遇到等号直接判非法，
  /// 于是每道题都要"打回重做"一次，耗时从 5 s 翻到 10 s、token 翻倍。
  /// 现在取等号左边求值；右边若是数字还会顺带核一遍，
  /// 左右对不上说明这道算式自相矛盾 → null（上层判 mismatch）。
  static Rational? eval(String input) {
    final eq = _splitEquals(_normalize(input));
    if (eq == null) return null;
    final left = _pure(eq.$1);
    if (left == null) return null;
    final right = eq.$2;
    if (right != null) {
      final rv = _pure(right);
      if (rv == null) return null;
      if (!matches(left, rv)) return null;
    }
    return left;
  }

  /// 拆等号。返回：(左边, 右边?)；右边为 null 表示原式没有等号。
  /// 返回 null 表示等号多于一个（`1+2=3=3`）或等号左边为空 —— 不猜，直接放弃验算。
  static (String, String?)? _splitEquals(String s) {
    final at = <int>[];
    for (var i = 0; i < s.length; i++) {
      if (s[i] == '=') at.add(i);
    }
    if (at.isEmpty) return (s, null);
    if (at.length > 1) return null;
    final p = at.single;
    final l = s.substring(0, p).trim();
    final r = s.substring(p + 1).trim();
    if (l.isEmpty) return null;
    return (l, r.isEmpty ? null : r);
  }

  /// 不含等号的纯四则求值（原来的 eval）。
  static Rational? _pure(String input) {
    final tokens = _tokenize(input);
    if (tokens == null || tokens.isEmpty) return null;
    final pos = _Cursor();
    final v = _expr(tokens, pos);
    if (v == null) return null;
    if (pos.i != tokens.length) return null;
    return v;
  }

  /// 数值比较：与 [expect] 的相对/绝对误差都在容差内。
  static bool matches(Rational a, Rational b) {
    final da = a.toDouble();
    final db = b.toDouble();
    if (da.isNaN || db.isNaN) return false;
    if ((da - db).abs() <= 1e-9) return true;
    return (da - db).abs() <= 1e-9 * (da.abs() + db.abs()) / 2;
  }

  static String _normalize(String s) => s
      .replaceAll('×', '*')
      .replaceAll('÷', '/')
      .replaceAll('−', '-')   // U+2212 减号
      .replaceAll('－', '-')   // U+FF0D 全角减号（模型很爱用）
      .replaceAll('–', '-')    // U+2013 en dash
      .replaceAll('（', '(')
      .replaceAll('）', ')')
      .replaceAll('＝', '=')
      .replaceAll('＋', '+')
      .replaceAll(',', '')
      .replaceAll(' ', '');

  static List<String>? _tokenize(String s) {
    final out = <String>[];
    var i = 0;
    while (i < s.length) {
      final c = s[i];
      if (c == '(' || c == ')' || c == '+' || c == '-' || c == '*' || c == '/') {
        out.add(c);
        i++;
      } else if (_isDigit(c) || c == '.') {
        var j = i;
        var dots = 0;
        while (j < s.length && (_isDigit(s[j]) || s[j] == '.')) {
          if (s[j] == '.') dots++;
          j++;
        }
        if (dots > 1) return null;
        out.add(s.substring(i, j));
        i = j;
      } else {
        return null; // 出现字母/汉字：这不是纯算式，验算放弃
      }
    }
    return out;
  }

  static bool _isDigit(String c) => c.codeUnitAt(0) >= 0x30 && c.codeUnitAt(0) <= 0x39;

  // 递归下降：expr := term (('+'|'-') term)*
  static Rational? _expr(List<String> t, _Cursor pos) {
    final first = _term(t, pos);
    if (first == null) return null;
    var acc = first;
    while (pos.i < t.length && (t[pos.i] == '+' || t[pos.i] == '-')) {
      final op = t[pos.i];
      pos.i++;
      final next = _term(t, pos);
      if (next == null) return null;
      acc = op == '+' ? acc + next : acc - next;
    }
    return acc;
  }

  static Rational? _term(List<String> t, _Cursor pos) {
    final first = _unary(t, pos);
    if (first == null) return null;
    var acc = first;
    while (pos.i < t.length && (t[pos.i] == '*' || t[pos.i] == '/')) {
      final op = t[pos.i];
      pos.i++;
      final next = _unary(t, pos);
      if (next == null) return null;
      if (op == '/' && next.toDouble() == 0) return null;
      acc = op == '*' ? acc * next : acc / next;
    }
    return acc;
  }

  static Rational? _unary(List<String> t, _Cursor pos) {
    if (pos.i < t.length && t[pos.i] == '-') {
      pos.i++;
      final v = _unary(t, pos);
      return v == null ? null : -v;
    }
    return _atom(t, pos);
  }

  static Rational? _atom(List<String> t, _Cursor pos) {
    if (pos.i >= t.length) return null;
    final tok = t[pos.i];
    if (tok == '(') {
      pos.i++;
      final v = _expr(t, pos);
      if (v == null || pos.i >= t.length || t[pos.i] != ')') return null;
      pos.i++;
      return v;
    }
    final r = Rational.tryParse(tok);
    if (r == null) return null;
    pos.i++;
    return r;
  }
}

/// 闭包指针，模拟 C 的 &pos（Dart 没有 out 参数，包一层最省事）。
class _Cursor {
  int i = 0;
}
