import 'dart:math' as math;

import '../../core/pt.dart';
import '../../core/rational.dart';
import '../dsl/figure.dart';

/// 度量与判定：面积、周长、自交检测、格点计数。
///
/// 这些是「答案本地算」和「正确性闸门」的地基 ——
/// 变体题生成后必须能本地算出答案并做合法性校验，绝不能让模型口算。
class Measure {
  /// 鞋带公式：任意简单多边形的有向面积（绝对值即面积）。
  static double shoelace(List<Pt> pts) {
    if (pts.length < 3) return 0;
    var s = 0.0;
    for (var i = 0; i < pts.length; i++) {
      final a = pts[i];
      final b = pts[(i + 1) % pts.length];
      s += a.x * b.y - b.x * a.y;
    }
    return s / 2;
  }

  /// 精确版鞋带公式（顶点为整数格点时可用有理数，答案绝对正确）。
  static Rational shoelaceExact(List<Pt> pts) {
    if (pts.length < 3) return Rational.zero;
    var acc = Rational.zero;
    for (var i = 0; i < pts.length; i++) {
      final a = pts[i];
      final b = pts[(i + 1) % pts.length];
      final ax = BigInt.from(a.x.round());
      final ay = BigInt.from(a.y.round());
      final bx = BigInt.from(b.x.round());
      final by = BigInt.from(b.y.round());
      acc = acc + Rational.fromBig(ax * by - bx * ay, BigInt.from(2));
    }
    return acc.abs;
  }

  static double perimeter(List<Pt> pts) {
    if (pts.length < 2) return 0;
    var s = 0.0;
    for (var i = 0; i < pts.length; i++) {
      s += pts[i].distTo(pts[(i + 1) % pts.length]);
    }
    return s;
  }

  /// 线段是否规范相交（不含共线重叠、不含共享端点）。
  static bool _segIntersect(Pt p1, Pt p2, Pt p3, Pt p4) {
    final d1 = (p2 - p1).cross(p3 - p1);
    final d2 = (p2 - p1).cross(p4 - p1);
    final d3 = (p4 - p3).cross(p1 - p3);
    final d4 = (p4 - p3).cross(p2 - p3);
    return ((d1 > 0 && d2 < 0) || (d1 < 0 && d2 > 0)) &&
        ((d3 > 0 && d4 < 0) || (d3 < 0 && d4 > 0));
  }

  /// 多边形是否简单（不自交）。
  /// 变体生成器每次产出都必须过这一关。
  static bool isSimplePolygon(List<Pt> pts) {
    final n = pts.length;
    if (n < 3) return false;
    for (var i = 0; i < n; i++) {
      final a1 = pts[i];
      final a2 = pts[(i + 1) % n];
      for (var j = i + 1; j < n; j++) {
        // 相邻边共享端点，跳过
        if (j == i || (j + 1) % n == i || j == (i + 1) % n) continue;
        final b1 = pts[j];
        final b2 = pts[(j + 1) % n];
        if (_segIntersect(a1, a2, b1, b2)) return false;
      }
    }
    return true;
  }

  /// 三点是否共线（退化三角形检测）。
  static bool isCollinear(Pt a, Pt b, Pt c, {double eps = 1e-9}) =>
      (b - a).cross(c - a).abs() < eps;

  /// 三边能否构成三角形。
  static bool isTriangle(num a, num b, num c) {
    final l = [a.toDouble(), b.toDouble(), c.toDouble()]..sort();
    return l[0] > 0 && l[0] + l[1] > l[2] + 1e-9;
  }

  /// 海伦公式（用边长求面积），用于与坐标法交叉校验。
  static double heron(num a, num b, num c) {
    final x = a.toDouble();
    final y = b.toDouble();
    final z = c.toDouble();
    final s = (x + y + z) / 2;
    final v = s * (s - x) * (s - y) * (s - z);
    return v <= 0 ? 0 : math.sqrt(v);
  }

  /// 点是否在多边形内（射线法），Pick 定理数内部格点用。
  static bool pointInPolygon(Pt p, List<Pt> pts) {
    var inside = false;
    final n = pts.length;
    for (var i = 0, j = n - 1; i < n; j = i++) {
      final a = pts[i];
      final b = pts[j];
      if (((a.y > p.y) != (b.y > p.y)) &&
          (p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x)) {
        inside = !inside;
      }
    }
    return inside;
  }

  /// 格点多边形边界上的格点数：Σ gcd(|dx|,|dy|)。
  static int latticeBoundaryCount(List<Pt> pts) {
    var b = 0;
    for (var i = 0; i < pts.length; i++) {
      final a = pts[i];
      final c = pts[(i + 1) % pts.length];
      final dx = (c.x - a.x).round().abs();
      final dy = (c.y - a.y).round().abs();
      b += _gcd(dx, dy);
    }
    return b;
  }

  /// 格点多边形内部格点数（不含边界）。
  ///
  /// 必须显式排除边界点：射线法 pointInPolygon 对落在边上的点判定不稳定，
  /// 会把边界点算进内部，导致 Pick 定理结果偏大（实测 5×4 矩形会算成 28 而非 20）。
  static int latticeInteriorCount(List<Pt> pts) {
    var minX = double.infinity, minY = double.infinity, maxX = -double.infinity, maxY = -double.infinity;
    for (final p in pts) {
      if (p.x < minX) minX = p.x;
      if (p.y < minY) minY = p.y;
      if (p.x > maxX) maxX = p.x;
      if (p.y > maxY) maxY = p.y;
    }
    var count = 0;
    for (var x = minX.ceil(); x <= maxX.floor(); x++) {
      for (var y = minY.ceil(); y <= maxY.floor(); y++) {
        final q = Pt(x.toDouble(), y.toDouble());
        if (_onBoundary(q, pts)) continue;
        if (pointInPolygon(q, pts)) count++;
      }
    }
    return count;
  }

  /// 点是否落在多边形的边上。
  static bool _onBoundary(Pt q, List<Pt> pts) {
    for (var i = 0; i < pts.length; i++) {
      final a = pts[i];
      final b = pts[(i + 1) % pts.length];
      if (_distToSegment(q, a, b) < 1e-9) return true;
    }
    return false;
  }

  /// 点到线段的距离。
  static double _distToSegment(Pt p, Pt a, Pt b) {
    final ab = b - a;
    final len2 = ab.len2;
    if (len2 < 1e-18) return p.distTo(a);
    var t = ((p - a).dot(ab)) / len2;
    if (t < 0) t = 0;
    if (t > 1) t = 1;
    return p.distTo(a + ab * t);
  }

  /// Pick 定理：S = I + B/2 − 1。
  /// 与鞋带公式交叉验证，两个结果不一致说明图形有问题。
  static double pickArea(List<Pt> pts) {
    final i = latticeInteriorCount(pts);
    final b = latticeBoundaryCount(pts);
    return i + b / 2.0 - 1;
  }

  static int _gcd(int a, int b) {
    var x = a.abs();
    var y = b.abs();
    while (y != 0) {
      final t = x % y;
      x = y;
      y = t;
    }
    return x;
  }

  /// 圆面积（返回含 π 的 Quantity）。
  static Quantity circleArea(num r, String unit) =>
      Quantity.pi(Rational.fromBig(BigInt.from(r.toInt())).pow(2), unit: '平方${unitName(unit)}');

  /// 圆周长。
  static Quantity circlePerimeter(num r, String unit) =>
      Quantity.pi(Rational.fromBig(BigInt.from(2 * r.toInt())), unit: unitName(unit));

  /// 扇形面积 = n/360 · πr²。
  static Quantity sectorArea(num r, num angleDeg, String unit) {
    final coef = Rational.fromBig(BigInt.from(r.toInt()) * BigInt.from(r.toInt()) * BigInt.from(angleDeg.toInt()),
        BigInt.from(360));
    return Quantity.pi(coef, unit: '平方${unitName(unit)}');
  }

  /// 扇形弧长 = n/360 · 2πr。
  static Quantity arcLength(num r, num angleDeg, String unit) {
    final coef = Rational.fromBig(BigInt.from(2) * BigInt.from(r.toInt()) * BigInt.from(angleDeg.toInt()),
        BigInt.from(360));
    return Quantity.pi(coef, unit: unitName(unit));
  }

  /// 圆环面积 = π(R² − r²)。
  static Quantity ringArea(num r, num R, String unit) {
    final rr = r.toInt();
    final RR = R.toInt();
    return Quantity.pi(Rational.fromBig(BigInt.from(RR * RR - rr * rr)), unit: '平方${unitName(unit)}');
  }

  /// 圆柱体积 = πr²h。
  static Quantity cylinderVolume(num r, num h, String unit) {
    final c = BigInt.from(r.toInt()) * BigInt.from(r.toInt()) * BigInt.from(h.toInt());
    return Quantity.pi(Rational.fromBig(c), unit: '立方${unitName(unit)}');
  }

  /// 圆柱表面积 = 2πr² + 2πrh。
  static Quantity cylinderSurface(num r, num h, String unit) {
    final rr = r.toInt();
    final hh = h.toInt();
    final c = BigInt.from(2 * rr * (rr + hh));
    return Quantity.pi(Rational.fromBig(c), unit: '平方${unitName(unit)}');
  }

  /// 圆锥体积 = 1/3 πr²h。
  static Quantity coneVolume(num r, num h, String unit) {
    final c = BigInt.from(r.toInt()) * BigInt.from(r.toInt()) * BigInt.from(h.toInt());
    return Quantity.pi(Rational.fromBig(c, BigInt.from(3)), unit: '立方${unitName(unit)}');
  }

  /// 长方体表面积 / 体积。
  static Quantity cuboidSurface(num w, num h, num d, String unit) {
    final a = w.toInt();
    final b = h.toInt();
    final c = d.toInt();
    return Quantity.num(Rational.fromBig(BigInt.from(2 * (a * b + b * c + a * c))), unit: '平方${unitName(unit)}');
  }

  static Quantity cuboidVolume(num w, num h, num d, String unit) {
    final a = w.toInt();
    final b = h.toInt();
    final c = d.toInt();
    return Quantity.num(Rational.fromBig(BigInt.from(a * b * c)), unit: '立方${unitName(unit)}');
  }

  /// 直角三角形：已知两直角边，求斜边（勾股，返回近似）。
  static double hypotenuse(num a, num b) => math.sqrt(a * a + b * b);
}
