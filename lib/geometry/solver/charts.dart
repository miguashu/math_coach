import 'dart:math' as math;

import '../../core/pt.dart';
import '../dsl/figure.dart';
import 'planar.dart';

/// 方格纸与统计图。
///
/// 统计图的验收要点（见方案 5.4）：
///   - 刻度与数据一致
///   - 扇形各扇区角度之和为 360°
class ChartBuilder {
  /// 方格纸。
  static FigureScene grid(FigureSpec s) {
    final cols = s.p('cols', 6).toInt();
    final rows = s.p('rows', 4).toInt();
    final step = s.p('step', 1).toDouble();

    final shapes = <Shape>[];
    for (var i = 0; i <= cols; i++) {
      shapes.add(SLine(Pt(i * step, 0), Pt(i * step, rows * step), LineStyle.thin));
    }
    for (var j = 0; j <= rows; j++) {
      shapes.add(SLine(Pt(0, j * step), Pt(cols * step, j * step), LineStyle.thin));
    }
    return FigureScene(
      shapes: shapes,
      labels: const [],
      dots: const [],
      extent: Box2(0, 0, cols * step, rows * step),
      facts: const FigureFacts({}),
    );
  }

  /// 条形统计图。
  static FigureScene barChart(FigureSpec s) {
    final values = s.list('values');
    if (values.isEmpty) throw const FigureSolveError('条形图缺少数据 values');
    final cats = s.strList('labels');
    final maxV = s.pOrNull('max');
    final top = (maxV ?? values.reduce(math.max)).toDouble();
    final height = s.p('height', 5).toDouble();
    final barW = s.p('barWidth', 0.8).toDouble();
    final gap = s.p('gap', 0.7).toDouble();

    final shapes = <Shape>[
      SLine(const Pt(0, 0), Pt(0, height)), // 纵轴
      SLine(const Pt(0, 0), Pt(values.length * (barW + gap), 0)), // 横轴
    ];

    final labels = <PlacedLabel>[];
    for (var i = 0; i < values.length; i++) {
      final v = values[i].toDouble();
      final h = top <= 0 ? 0.0 : (v / top) * height;
      final x0 = i * (barW + gap) + gap / 2;
      shapes.add(SPolyline([
        Pt(x0, 0),
        Pt(x0, h),
        Pt(x0 + barW, h),
        Pt(x0 + barW, 0),
      ], closed: true, fill: FillStyle.shade));
      labels.add(PlacedLabel(Pt(x0 + barW / 2, h + 0.35), _n(v), kind: LabelKind.note));
      if (i < cats.length) {
        labels.add(PlacedLabel(Pt(x0 + barW / 2, -0.55), cats[i], kind: LabelKind.note));
      }
    }
    // 刻度：0 / 半程 / 顶
    for (final frac in [0.0, 0.5, 1.0]) {
      final y = frac * height;
      shapes.add(SLine(Pt(-0.18, y), Pt(0, y), LineStyle.thin));
      labels.add(PlacedLabel(Pt(-0.75, y), _n(frac * top), kind: LabelKind.note));
    }

    final pts = [const Pt(0, 0), Pt(values.length * (barW + gap), height)];
    return FigureScene(
      shapes: shapes,
      labels: labels,
      dots: const [],
      extent: Box2.fromPoints(pts),
      facts: FigureFacts({
        'total': Quantity(approx: values.fold<double>(0, (a, b) => a + b.toDouble())),
        'max': Quantity(approx: top),
      }),
    );
  }

  /// 折线统计图。
  static FigureScene lineChart(FigureSpec s) {
    final values = s.list('values');
    if (values.isEmpty) throw const FigureSolveError('折线图缺少数据 values');
    final cats = s.strList('labels');
    final maxV = s.pOrNull('max');
    final top = (maxV ?? values.reduce(math.max)).toDouble();
    final height = s.p('height', 5).toDouble();
    final stepX = s.p('stepX', 1.4).toDouble();

    final pts = <Pt>[];
    for (var i = 0; i < values.length; i++) {
      final v = values[i].toDouble();
      pts.add(Pt(i * stepX, top <= 0 ? 0 : (v / top) * height));
    }

    final shapes = <Shape>[
      SLine(const Pt(0, 0), Pt(0, height)),
      SLine(const Pt(0, 0), Pt((values.length - 1) * stepX, 0)),
      SPolyline(pts),
    ];

    final labels = <PlacedLabel>[];
    for (var i = 0; i < pts.length; i++) {
      shapes.add(SCircle(pts[i], 0.05, style: LineStyle.solid, fill: FillStyle.shade));
      labels.add(PlacedLabel(pts[i] + const Pt(0, 0.4), _n(values[i].toDouble()), kind: LabelKind.note));
      if (i < cats.length) {
        labels.add(PlacedLabel(Pt(pts[i].x, -0.55), cats[i], kind: LabelKind.note));
      }
    }

    final boxPts = [const Pt(0, 0), Pt((values.length - 1) * stepX, height)];
    return FigureScene(
      shapes: shapes,
      labels: labels,
      dots: pts,
      extent: Box2.fromPoints(boxPts),
      facts: FigureFacts({
        'total': Quantity(approx: values.fold<double>(0, (a, b) => a + b.toDouble())),
      }),
    );
  }

  /// 扇形统计图：各扇区角度之和必须严格等于 360°（本地校验）。
  static FigureScene pieChart(FigureSpec s) {
    final values = s.list('values');
    if (values.isEmpty) throw const FigureSolveError('扇形图缺少数据 values');
    final cats = s.strList('labels');
    final r = s.p('r', 3).toDouble();
    final O = Pt.zero;

    final total = values.fold<double>(0, (a, b) => a + b.toDouble());
    if (total <= 0) throw const FigureSolveError('扇形图数据总和必须大于 0');

    final shapes = <Shape>[];
    final labels = <PlacedLabel>[];
    var start = 0.0;
    var sumDeg = 0.0;

    for (var i = 0; i < values.length; i++) {
      final deg = values[i].toDouble() / total * 360;
      final sweep = Ang.rad(deg);
      sumDeg += deg;
      shapes.add(SArc(O, r, start, sweep, closedToCenter: true, fill: FillStyle.hatch));
      if (i < cats.length) {
        final mid = start + sweep / 2;
        labels.add(PlacedLabel(
          Pt(r * 0.62 * math.cos(mid), r * 0.62 * math.sin(mid)),
          '${cats[i]} ${_n(deg / 360 * 100)}%',
          kind: LabelKind.note,
        ));
      }
      start += sweep;
    }

    // 校验：角度之和必须是 360°
    if ((sumDeg - 360).abs() > 1e-6) {
      throw const FigureSolveError('扇形统计图各扇区角度之和不等于 360°');
    }

    return FigureScene(
      shapes: shapes,
      labels: labels,
      dots: const [],
      extent: Box2(-r, -r, r, r),
      facts: FigureFacts({
        'total': Quantity(approx: total),
      }),
    );
  }
}

String _n(double v) {
  if ((v - v.roundToDouble()).abs() < 1e-9) return v.round().toString();
  final s = v.toStringAsFixed(2);
  return s.replaceAll(RegExp(r'0+$'), '').replaceAll(RegExp(r'\.$'), '');
}
