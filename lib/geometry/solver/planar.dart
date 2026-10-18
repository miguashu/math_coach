import 'dart:math' as math;

import '../../core/pt.dart';
import '../../core/rational.dart';
import '../dsl/figure.dart';
import 'measure.dart';

/// 平面图形求解器。
///
/// 每个 builder 做两件事：
///   1) 把语义参数解析式地变成坐标（比例一定真实：6cm 的边就是 4cm 边的 1.5 倍）
///   2) 本地算出答案（FigureFacts），模型不参与给数
class PlanarBuilder {
  static FigureScene rect(FigureSpec s) {
    final w = s.p('w', 6).toDouble();
    final h = s.p('h', 4).toDouble();
    final a = const Pt(0, 0);
    final b = Pt(w, 0);
    final c = Pt(w, h);
    final d = Pt(0, h);
    final pts = [a, b, c, d];

    final shapes = <Shape>[
      SPolyline(pts, closed: true, fill: s.shade ? FillStyle.shade : FillStyle.none),
    ];
    final labels = <PlacedLabel>[
      PlacedLabel(Pt(w / 2, -0.45), s.t('w', '${_n(w)} ${s.unit}'), kind: LabelKind.length),
      PlacedLabel(Pt(-0.5, h / 2), s.t('h', '${_n(h)} ${s.unit}'), kind: LabelKind.length),
    ];

    return _pack(shapes, pts, labels: labels,facts: {
      'area': Quantity.num(Rational.fromBig(BigInt.from(w.round()) * BigInt.from(h.round())), unit: '平方${unitName(s.unit)}'),
      'perimeter': Quantity.num(Rational.fromBig(BigInt.from(2 * (w.round() + h.round()))), unit: unitName(s.unit)),
    });
  }

  static FigureScene square(FigureSpec s) {
    final a = s.p('a', 4).toDouble();
    return rect(s.copyWith(params: {'w': a, 'h': a}));
  }

  /// 直角三角形：直角在 A，两直角边 a（底）、b（高）。
  static FigureScene triangleRight(FigureSpec s) {
    final a = s.p('a', 6).toDouble();
    final b = s.p('b', 4).toDouble();
    final A = const Pt(0, 0);
    final B = Pt(a, 0);
    final C = Pt(0, b);
    final pts = [A, B, C];

    final shapes = <Shape>[
      SPolyline(pts, closed: true, fill: s.shade ? FillStyle.shade : FillStyle.none),
      SRightAngle(A, (B - A).unit, (C - A).unit),
    ];
    final labels = <PlacedLabel>[
      PlacedLabel(Pt(-0.42, -0.3), 'A', kind: LabelKind.point),
      PlacedLabel(Pt(a + 0.42, -0.3), 'B', kind: LabelKind.point),
      PlacedLabel(Pt(-0.42, b + 0.38), 'C', kind: LabelKind.point),
      PlacedLabel(Pt(a / 2, -0.45), s.t('a', '${_n(a)} ${s.unit}'), kind: LabelKind.length),
      PlacedLabel(Pt(-0.55, b / 2), s.t('b', '${_n(b)} ${s.unit}'), kind: LabelKind.length),
    ];

    final areaR = Rational.fromBig(BigInt.from(a.round()) * BigInt.from(b.round()), BigInt.from(2));
    return _pack(shapes, pts, labels: labels,facts: {
      'area': Quantity.num(areaR, unit: '平方${unitName(s.unit)}'),
      'hypotenuse': Quantity(approx: Measure.hypotenuse(a, b), unit: unitName(s.unit)),
    });
  }

  /// 一般三角形：已知底 a、高 h、垂足位置 foot（0~1，底边上从 B 起的比例）。
  /// 坐标完全由底和高决定，画出来的高必然等于题面给的高，
  /// 根因教训：绝不能反过来先编三条边再画图——那样解出的高与题面不一致。
  /// 题面没给边长，所以只标底和高，不标两条斜边。
  static FigureScene triangleGeneral(FigureSpec s) {
    final a = s.p('a', 6).toDouble();
    final h = s.p('h', 4).toDouble();
    // 垂足位置：默认 0.35 偏左，画出来是斜三角形；限制在中间区域避免退化成直角
    var foot = s.p('foot', 0.35).toDouble();
    foot = foot.clamp(0.15, 0.85);

    if (a <= 0 || h <= 0) {
      throw const FigureSolveError('三角形的底和高必须为正');
    }

    final B = const Pt(0, 0);
    final C = Pt(a, 0);
    final A = Pt(a * foot, h);
    final pts = [A, B, C];

    final shapes = <Shape>[
      SPolyline([A, B, C], closed: true, fill: s.shade ? FillStyle.shade : FillStyle.none),
    ];

    // 高：从 A 向 BC 作垂线
    final footPt = Pt(A.x, 0);
    shapes.add(SLine(A, footPt, LineStyle.dashed));

    final labels = <PlacedLabel>[
      PlacedLabel(Pt(A.x, h + 0.4), 'A', kind: LabelKind.point),
      PlacedLabel(Pt(-0.42, -0.3), 'B', kind: LabelKind.point),
      PlacedLabel(Pt(a + 0.42, -0.3), 'C', kind: LabelKind.point),
      PlacedLabel(Pt(a / 2, -0.45), s.t('a', '${_n(a)} ${s.unit}'), kind: LabelKind.length),
      PlacedLabel(_mid(A, footPt) + const Pt(0.55, 0), s.t('h', '${_n(h)} ${s.unit}'), kind: LabelKind.length),
    ];

    final perim = A.distTo(B) + a + C.distTo(A);
    return _pack(shapes, pts, labels: labels, facts: {
      'area': Quantity.num(Rational.fromBig(
          BigInt.from(a.round()) * BigInt.from(h.round()), BigInt.from(2)),
          unit: '平方${unitName(s.unit)}'),
      'perimeter': Quantity.num(
          Rational.fromBig(BigInt.from(perim.round())), unit: unitName(s.unit)),
    });
  }

  /// 平行四边形：底 b、高 h、水平偏移 o。
  static FigureScene parallelogram(FigureSpec s) {
    final b = s.p('base', 6).toDouble();
    final h = s.p('height', 4).toDouble();
    final o = s.p('offset', 2).toDouble();

    final A = const Pt(0, 0);
    final B = Pt(b, 0);
    final C = Pt(b + o, h);
    final D = Pt(o, h);
    final pts = [A, B, C, D];

    final foot = Pt(o, 0);
    final shapes = <Shape>[
      SPolyline(pts, closed: true, fill: s.shade ? FillStyle.shade : FillStyle.none),
      SLine(D, foot, LineStyle.dashed),
      SRightAngle(foot, (Pt(0, 0) - foot).unit, (D - foot).unit),
    ];
    final labels = <PlacedLabel>[
      PlacedLabel(Pt(b / 2, -0.45), s.t('base', '${_n(b)} ${s.unit}'), kind: LabelKind.length),
      PlacedLabel(Pt(o - 0.5, h / 2), s.t('height', '${_n(h)} ${s.unit}'), kind: LabelKind.length),
    ];

    return _pack(shapes, pts, labels: labels,facts: {
      'area': Quantity.num(
          Rational.fromBig(BigInt.from(b.round()) * BigInt.from(h.round())), unit: '平方${unitName(s.unit)}'),
      'perimeter': Quantity(approx: 2 * (b + (C - B).len), unit: unitName(s.unit)),
    });
  }

  /// 梯形：上底 top、下底 bottom、高 height（等腰，上底居中）。
  static FigureScene trapezoid(FigureSpec s) {
    final top = s.p('top', 4).toDouble();
    final bottom = s.p('bottom', 8).toDouble();
    final h = s.p('height', 5).toDouble();

    final A = const Pt(0, 0);
    final B = Pt(bottom, 0);
    final x0 = (bottom - top) / 2;
    final D = Pt(x0, h);
    final C = Pt(x0 + top, h);
    final pts = [A, B, C, D];

    final foot = Pt(x0, 0);
    final shapes = <Shape>[
      SPolyline(pts, closed: true, fill: s.shade ? FillStyle.shade : FillStyle.none),
      SLine(D, foot, LineStyle.dashed),
      SRightAngle(foot, (Pt(0, 0) - foot).unit, (D - foot).unit),
    ];
    final labels = <PlacedLabel>[
      PlacedLabel(Pt(bottom / 2, -0.45), s.t('bottom', '下底 ${_n(bottom)} ${s.unit}'), kind: LabelKind.length),
      PlacedLabel(Pt(x0 + top / 2, h + 0.45), s.t('top', '上底 ${_n(top)} ${s.unit}'), kind: LabelKind.length),
      PlacedLabel(Pt(x0 - 0.5, h / 2), s.t('height', '${_n(h)} ${s.unit}'), kind: LabelKind.length),
    ];

    final areaR = Rational.fromBig(
        BigInt.from(top.round() + bottom.round()) * BigInt.from(h.round()), BigInt.from(2));
    return _pack(shapes, pts, labels: labels,facts: {
      'area': Quantity.num(areaR, unit: '平方${unitName(s.unit)}'),
    });
  }

  /// 圆：半径线从圆心指向圆周（实线），直径穿过圆心（虚线）。
  /// 这两条线的画法在教材里有约定，由渲染器硬编码，不让模型猜。
  static FigureScene circle(FigureSpec s) {
    final r = s.p('r', 3).toDouble();
    final O = Pt.zero;
    final ang = Ang.rad(35);
    final P = Pt(r * math.cos(ang), r * math.sin(ang));
    final Q = Pt(-r, 0);
    final R = Pt(r, 0);

    final shapes = <Shape>[
      SCircle(O, r, fill: s.shade ? FillStyle.shade : FillStyle.none),
      SLine(O, P, LineStyle.bold),
      SLine(Q, R, LineStyle.dashed),
    ];
    final labels = <PlacedLabel>[
      PlacedLabel(Pt(-0.35, 0.42), 'O', kind: LabelKind.point),
      PlacedLabel(P * 0.62 + const Pt(0.15, 0.35), s.t('r', 'r = ${_n(r)} ${s.unit}'), kind: LabelKind.length),
      PlacedLabel(Pt(0, -0.5), s.t('d', 'd = ${_n(2 * r)} ${s.unit}'), kind: LabelKind.length),
    ];
    final pts = [Pt(-r, -r), Pt(r, r)];

    return _pack(shapes, pts, labels: labels,dots: [O, P], facts: {
      'area': Measure.circleArea(r, s.unit),
      'circumference': Measure.circlePerimeter(r, s.unit),
    });
  }

  static FigureScene semicircle(FigureSpec s) {
    final r = s.p('r', 3).toDouble();
    final O = Pt.zero;
    final shapes = <Shape>[
      SArc(O, r, 0, math.pi, closedToCenter: true, fill: s.shade ? FillStyle.shade : FillStyle.none),
    ];
    final labels = <PlacedLabel>[
      PlacedLabel(Pt(0, r / 2 + 0.15) + const Pt(0.0, 0.0), s.t('r', 'r = ${_n(r)} ${s.unit}'), kind: LabelKind.length),
      PlacedLabel(Pt(0, -0.45), s.t('d', 'd = ${_n(2 * r)} ${s.unit}'), kind: LabelKind.length),
    ];
    final pts = [Pt(-r, 0), Pt(r, 0), Pt(0, r)];
    return _pack(shapes, pts, labels: labels,dots: [O], facts: {
      'area': Quantity.pi(
          Rational.fromBig(BigInt.from(r.round()) * BigInt.from(r.round()), BigInt.from(2)),
          unit: '平方${unitName(s.unit)}'),
      // 半圆周长 = 弧长 πr + 直径 2r
      'perimeter': Quantity(
        approx: math.pi * r + 2 * r,
        unit: unitName(s.unit),
        withPi: '${_n(r)}π+${_n(2 * r)}',
      ),
    });
  }

  /// 扇形：两条半径 + 弧 + 可选阴影。圆心角标注落在扇形内部。
  static FigureScene sector(FigureSpec s) {
    final r = s.p('r', 3).toDouble();
    final deg = s.p('angleDeg', 120).toDouble();
    final O = Pt.zero;
    final a0 = Ang.rad(s.p('startDeg', 0).toDouble());
    final sweep = Ang.rad(deg);

    final shapes = <Shape>[
      SArc(O, r, a0, sweep, closedToCenter: true, fill: s.shade ? FillStyle.shade : FillStyle.none),
      SArc(O, r * 0.42, a0, sweep, style: LineStyle.thin),
    ];
    final mid = a0 + sweep / 2;
    final labels = <PlacedLabel>[
      PlacedLabel(Pt(r * 0.62 * math.cos(mid), r * 0.62 * math.sin(mid)),
          s.t('angle', '${_n(deg)}°'), kind: LabelKind.angle),
      PlacedLabel(Pt(r * 0.5 * math.cos(a0), r * 0.5 * math.sin(a0)) + const Pt(0, -0.45),
          s.t('r', 'r = ${_n(r)} ${s.unit}'), kind: LabelKind.length),
    ];
    final pts = [Pt(-r, -r), Pt(r, r)];
    return _pack(shapes, pts, labels: labels,dots: [O], facts: {
      'area': Measure.sectorArea(r, deg, s.unit),
      'arcLength': Measure.arcLength(r, deg, s.unit),
    });
  }

  /// 圆环：内圆 r、外圆 R。
  static FigureScene ring(FigureSpec s) {
    final r = s.p('r', 2).toDouble();
    final R = s.p('R', 4).toDouble();
    if (R <= r) throw const FigureSolveError('外半径必须大于内半径');
    final O = Pt.zero;
    final shapes = <Shape>[
      SCircle(O, R),
      SCircle(O, r),
    ];
    if (s.shade) {
      // 阴影环：外圆填充 + 内圆挖空（渲染器按 fill=none 的内圆做背景色覆盖）
      shapes.add(SCircle(O, (R + r) / 2, style: LineStyle.thin, fill: FillStyle.hatch));
    }
    final labels = <PlacedLabel>[
      PlacedLabel(Pt(-0.35, 0.42), 'O', kind: LabelKind.point),
      PlacedLabel(Pt(R * 0.72, R * 0.72), s.t('R', 'R = ${_n(R)} ${s.unit}'), kind: LabelKind.length),
      PlacedLabel(Pt(r * 0.72, r * 0.72), s.t('r', 'r = ${_n(r)} ${s.unit}'), kind: LabelKind.length),
    ];
    final pts = [Pt(-R, -R), Pt(R, R)];
    return _pack(shapes, pts, labels: labels,dots: [O], facts: {
      'area': Measure.ringArea(r, R, s.unit),
    });
  }

  /// 组合图形：矩形 + 上方半圆（半圆直径严格等于矩形上边）。
  static FigureScene compositeRectSemicircle(FigureSpec s) {
    final w = s.p('w', 6).toDouble();
    final h = s.p('h', 4).toDouble();
    final r = w / 2;

    final A = const Pt(0, 0);
    final B = Pt(w, 0);
    final C = Pt(w, h);
    final D = Pt(0, h);
    final shapes = <Shape>[
      SPolyline([A, B, C, D], closed: true, fill: FillStyle.none),
      SArc(Pt(w / 2, h), r, 0, math.pi, closedToCenter: true,
          fill: s.shade ? FillStyle.shade : FillStyle.none),
    ];
    final labels = <PlacedLabel>[
      PlacedLabel(Pt(w / 2, -0.45), s.t('w', '${_n(w)} ${s.unit}'), kind: LabelKind.length),
      PlacedLabel(Pt(-0.5, h / 2), s.t('h', '${_n(h)} ${s.unit}'), kind: LabelKind.length),
      PlacedLabel(Pt(w / 2 + r * 0.55, h + r * 0.7), s.t('r', '半径 ${_n(r)} ${s.unit}'),
          kind: LabelKind.length),
    ];
    final pts = [Pt(0, 0), Pt(w, h + r)];

    final rectArea = Rational.fromBig(BigInt.from(w.round()) * BigInt.from(h.round()));
    final semiArea = Rational.fromBig(BigInt.from(r.round()) * BigInt.from(r.round()), BigInt.from(2));
    return _pack(shapes, pts, labels: labels,facts: {
      'rectArea': Quantity.num(rectArea, unit: '平方${unitName(s.unit)}'),
      'semicircleArea': Quantity.pi(semiArea, unit: '平方${unitName(s.unit)}'),
      'area': Quantity(approx: rectArea.toDouble() + semiArea.toDouble() * math.pi,
          unit: '平方${unitName(s.unit)}', withPi: '${rectArea.toString()}+${semiArea.toString()}π'),
    });
  }

  /// 正方形内切圆：阴影为四个角（正方形减圆）。
  static FigureScene compositeSquareCircle(FigureSpec s) {
    final a = s.p('a', 6).toDouble();
    final r = a / 2;
    final A = const Pt(0, 0);
    final B = Pt(a, 0);
    final C = Pt(a, a);
    final D = Pt(0, a);
    final O = Pt(a / 2, a / 2);

    final shapes = <Shape>[
      SPolyline([A, B, C, D], closed: true, fill: s.shade ? FillStyle.hatch : FillStyle.none),
      SCircle(O, r, fill: s.shade ? FillStyle.shade : FillStyle.none),
    ];
    final labels = <PlacedLabel>[
      PlacedLabel(Pt(a / 2, -0.45), s.t('a', '${_n(a)} ${s.unit}'), kind: LabelKind.length),
      PlacedLabel(O + Pt(r * 0.62, r * 0.62), s.t('r', 'r = ${_n(r)} ${s.unit}'), kind: LabelKind.length),
    ];
    final pts = [A, C];

    final sqArea = Rational.fromBig(BigInt.from(a.round()) * BigInt.from(a.round()));
    final cirArea = Rational.fromBig(BigInt.from(r.round()) * BigInt.from(r.round()));
    return _pack(shapes, pts, labels: labels,dots: [O], facts: {
      'squareArea': Quantity.num(sqArea, unit: '平方${unitName(s.unit)}'),
      'circleArea': Quantity.pi(cirArea, unit: '平方${unitName(s.unit)}'),
      'cornerArea': Quantity(approx: sqArea.toDouble() - cirArea.toDouble() * math.pi,
          unit: '平方${unitName(s.unit)}', withPi: '${sqArea.toString()}−${cirArea.toString()}π'),
    });
  }

  // ── 内部工具 ──────────────────────────────────────────────

  static Pt _mid(Pt a, Pt b) => Pt((a.x + b.x) / 2, (a.y + b.y) / 2);

  static String _n(double v) {
    if ((v - v.roundToDouble()).abs() < 1e-9) return v.round().toString();
    final s = v.toStringAsFixed(2);
    return s.replaceAll(RegExp(r'0+$'), '').replaceAll(RegExp(r'\.$'), '');
  }

  static FigureScene _pack(
    List<Shape> shapes,
    List<Pt> bboxPts, {
    List<PlacedLabel> labels = const [],
    List<Pt> dots = const [],
    Map<String, Quantity>? facts,
  }) =>
      FigureScene(
        shapes: shapes,
        labels: labels,
        dots: dots,
        extent: Box2.fromPoints(bboxPts),
        facts: FigureFacts(facts ?? const {}),
      );
}

/// 求解失败（参数不合法 / 图形退化）。
/// 调用方应据此触发「重新生成一次，仍失败则降级为无配图」。
class FigureSolveError implements Exception {
  final String message;
  const FigureSolveError(this.message);

  @override
  String toString() => 'FigureSolveError: $message';
}

