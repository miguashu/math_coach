/// 精确有理数。
///
/// 为什么不用 double：本 App 的核心承诺是「答案不能错」。
/// 凡是本地能算的（数值运算、面积体积、单位换算、变体答案）一律用有理数算，
/// 避免 0.1+0.2 这类浮点误差导致「本地算的和模型给的」比对失败。
class Rational implements Comparable<Rational> {
  /// 分子，可以为负。
  final BigInt n;

  /// 分母，恒为正，且与 n 互质。
  final BigInt d;

  const Rational._(this.n, this.d);

  static final Rational zero = Rational._(BigInt.zero, BigInt.one);
  static final Rational one = Rational._(BigInt.one, BigInt.one);

  factory Rational(int n, [int d = 1]) => Rational.fromBig(BigInt.from(n), BigInt.from(d));

  factory Rational.fromBig(BigInt n, [BigInt? d]) {
    final den = d ?? BigInt.one;
    if (den == BigInt.zero) {
      throw ArgumentError('分母不能为 0');
    }
    var a = n;
    var b = den;
    if (b < BigInt.zero) {
      a = -a;
      b = -b;
    }
    final g = a.gcd(b);
    // gcd 可能为负（当 a 为负时 BigInt.gcd 返回非负，保险起见再取绝对值）
    final gg = g.abs();
    return Rational._(a ~/ gg, b ~/ gg);
  }

  factory Rational.fromInt(int v) => Rational._(BigInt.from(v), BigInt.one);

  /// 从字符串解析：整数 "12"、小数 "3.14"、分数 "3/4"、带负号 "-1/2"。
  static Rational? tryParse(String s) {
    final t = s.trim().replaceAll(' ', '');
    if (t.isEmpty) return null;
    if (t.contains('/')) {
      final parts = t.split('/');
      if (parts.length != 2) return null;
      final a = BigInt.tryParse(parts[0]);
      final b = BigInt.tryParse(parts[1]);
      if (a == null || b == null || b == BigInt.zero) return null;
      return Rational.fromBig(a, b);
    }
    if (t.contains('.')) {
      final neg = t.startsWith('-');
      final body = neg ? t.substring(1) : t;
      final parts = body.split('.');
      if (parts.length != 2) return null;
      final intPart = parts[0].isEmpty ? '0' : parts[0];
      final fracPart = parts[1];
      if (!RegExp(r'^\d+$').hasMatch(intPart) || !RegExp(r'^\d+$').hasMatch(fracPart)) return null;
      final scale = BigInt.from(10).pow(fracPart.length);
      final num = (BigInt.parse(intPart) * scale) + BigInt.parse(fracPart);
      return Rational.fromBig(neg ? -num : num, scale);
    }
    final v = BigInt.tryParse(t);
    if (v == null) return null;
    return Rational._(v, BigInt.one);
  }

  bool get isZero => n == BigInt.zero;
  bool get isInteger => d == BigInt.one;
  bool get isNegative => n < BigInt.zero;

  Rational get abs => Rational._(n.abs(), d);

  Rational operator +(Rational o) =>
      Rational.fromBig(n * o.d + o.n * d, d * o.d);

  Rational operator -(Rational o) =>
      Rational.fromBig(n * o.d - o.n * d, d * o.d);

  Rational operator *(Rational o) => Rational.fromBig(n * o.n, d * o.d);

  Rational operator /(Rational o) {
    if (o.n == BigInt.zero) throw ArgumentError('除以零');
    return Rational.fromBig(n * o.d, d * o.n);
  }

  Rational operator -() => Rational._(-n, d);

  /// 整数次幂（小学范围内够用）。
  Rational pow(int e) {
    if (e == 0) return one;
    if (e < 0) return Rational.fromBig(d.pow(-e), n.pow(-e));
    return Rational.fromBig(n.pow(e), d.pow(e));
  }

  @override
  int compareTo(Rational other) {
    final l = n * other.d;
    final r = other.n * d;
    return l.compareTo(r);
  }

  bool operator <(Rational o) => compareTo(o) < 0;
  bool operator <=(Rational o) => compareTo(o) <= 0;
  bool operator >(Rational o) => compareTo(o) > 0;
  bool operator >=(Rational o) => compareTo(o) >= 0;

  @override
  bool operator ==(Object other) => other is Rational && n == other.n && d == other.d;

  @override
  int get hashCode => Object.hash(n, d);

  double toDouble() => n.toDouble() / d.toDouble();

  /// 分母只含 2 和 5 时，小数表示是有限小数。
  bool get hasFiniteDecimal {
    var t = d;
    while (t % BigInt.two == BigInt.zero) {
      t = t ~/ BigInt.two;
    }
    while (t % BigInt.from(5) == BigInt.zero) {
      t = t ~/ BigInt.from(5);
    }
    return t == BigInt.one;
  }

  /// 展示用字符串：
  /// - 整数 → "12"
  /// - 有限小数 → "0.75"
  /// - 否则 → 分数 "3/7"（小学阶段分数答案本身就是常见形式）
  @override
  String toString() {
    if (isInteger) return n.toString();
    if (hasFiniteDecimal) {
      final s = toDouble().toStringAsFixed(10);
      final trimmed = s.replaceAll(RegExp(r'0+$'), '').replaceAll(RegExp(r'\.$'), '');
      return trimmed;
    }
    return '$n/$d';
  }

  /// 分数形式，如 "3/4"；整数则直接返回数字。
  String toFractionString() => isInteger ? n.toString() : '$n/$d';

  /// 带分数形式，如 "1又3/4"（小学分数题常用）。
  String toMixedString() {
    if (isInteger) return n.toString();
    final sign = n < BigInt.zero ? '-' : '';
    final a = n.abs();
    final whole = a ~/ d;
    final rem = a % d;
    if (whole == BigInt.zero) return '$sign$rem/$d';
    if (rem == BigInt.zero) return '$sign$whole';
    return '$sign$whole又$rem/$d';
  }
}
