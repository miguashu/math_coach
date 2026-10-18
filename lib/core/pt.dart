import 'dart:math' as math;

/// 二维点 / 向量。
///
/// 刻意不依赖 dart:ui：几何引擎是纯 Dart，
/// 这样它既能被 CustomPainter 用，也能被 PdfGraphics 用，还能脱离 Flutter 单测。
class Pt {
  final double x;
  final double y;

  const Pt(this.x, this.y);

  static const Pt zero = Pt(0, 0);

  Pt operator +(Pt o) => Pt(x + o.x, y + o.y);
  Pt operator -(Pt o) => Pt(x - o.x, y - o.y);
  Pt operator *(double k) => Pt(x * k, y * k);
  Pt operator /(double k) => Pt(x / k, y / k);
  Pt operator -() => Pt(-x, -y);

  double dot(Pt o) => x * o.x + y * o.y;

  /// 二维叉积（标量），>0 表示 o 在 this 的逆时针方向。
  double cross(Pt o) => x * o.y - y * o.x;

  double get len => math.sqrt(x * x + y * y);
  double get len2 => x * x + y * y;

  Pt get unit {
    final l = len;
    return l < 1e-12 ? Pt.zero : Pt(x / l, y / l);
  }

  /// 左法向（逆时针 90°）。
  Pt get perp => Pt(-y, x);

  double distTo(Pt o) => (this - o).len;

  Pt rotated(double rad) {
    final c = math.cos(rad);
    final s = math.sin(rad);
    return Pt(x * c - y * s, x * s + y * c);
  }

  /// 绕 pivot 旋转 rad 弧度。
  Pt rotatedAround(Pt pivot, double rad) => (this - pivot).rotated(rad) + pivot;

  Pt lerp(Pt o, double t) => Pt(x + (o.x - x) * t, y + (o.y - y) * t);

  /// 沿本方向（视为从 origin 出发）延长到长度 l。
  Pt scaledTo(double l) => unit * l;

  @override
  bool operator ==(Object other) =>
      other is Pt && (other.x - x).abs() < 1e-9 && (other.y - y).abs() < 1e-9;

  @override
  int get hashCode => Object.hash((x * 1e9).round(), (y * 1e9).round());

  @override
  String toString() => 'Pt(${_f(x)}, ${_f(y)})';

  static String _f(double v) {
    final r = (v * 1e6).round() / 1e6;
    return r.toStringAsFixed(r == r.roundToDouble() ? 0 : 6).replaceAll(RegExp(r'0+$'), '').replaceAll(RegExp(r'\.$'), '');
  }
}

/// 轴对齐矩形（数学坐标系，y 向上）。
class Box2 {
  final double minX;
  final double minY;
  final double maxX;
  final double maxY;

  const Box2(this.minX, this.minY, this.maxX, this.maxY);

  factory Box2.fromPoints(Iterable<Pt> pts) {
    var a = double.infinity, b = double.infinity, c = -double.infinity, d = -double.infinity;
    for (final p in pts) {
      if (p.x < a) a = p.x;
      if (p.y < b) b = p.y;
      if (p.x > c) c = p.x;
      if (p.y > d) d = p.y;
    }
    return Box2(a, b, c, d);
  }

  double get w => maxX - minX;
  double get h => maxY - minY;
  Pt get center => Pt((minX + maxX) / 2, (minY + maxY) / 2);
  bool get isEmpty => w <= 0 || h <= 0;

  Box2 pad(double m) => Box2(minX - m, minY - m, maxX + m, maxY + m);

  bool contains(Pt p) =>
      p.x >= minX - 1e-9 && p.x <= maxX + 1e-9 && p.y >= minY - 1e-9 && p.y <= maxY + 1e-9;
}

/// 角度工具：全部用弧度 internally，对外用度。
class Ang {
  static double rad(double deg) => deg * math.pi / 180.0;
  static double deg(double rad) => rad * 180.0 / math.pi;

  /// 归一化到 [0, 2π)。
  static double norm2pi(double a) {
    var r = a % (2 * math.pi);
    if (r < 0) r += 2 * math.pi;
    return r;
  }

  /// 归一化到 (-π, π]。
  static double normPi(double a) {
    var r = norm2pi(a);
    if (r > math.pi) r -= 2 * math.pi;
    return r;
  }
}
