import '../../core/pt.dart';
import '../dsl/figure.dart';
import 'charts.dart';
import 'lattice.dart';
import 'measure.dart';
import 'planar.dart';
import 'solid.dart';

/// 几何求解器总入口。
///
/// 模型 → 语义 DSL → 【本地求解】→ FigureScene（坐标）+ FigureFacts（答案）
///                          ↓
///                   Canvas 渲染器 / PDF 渲染器（共用同一份 FigureScene）
class FigureSolver {
  const FigureSolver._();

  /// 求解。失败时抛 FigureSolveError，调用方应重生成一次，
  /// 仍失败则降级为"无配图 + 文字描述"（见方案异常兜底）。
  static SolveResult solve(FigureSpec spec) {
    final scene = _dispatch(spec);
    final warnings = <String>[];

    // ── 退化校验：面积为零 / 包围盒为空 / 出现 NaN ──
    _validate(scene, warnings);

    // ── 方格纸叠加 ──
    final withGrid = spec.grid && spec.type != FigureType.latticePolygon
        ? _overlayGrid(scene, spec.gridStep.toDouble())
        : scene;

    // ── 标注避让 ──
    final finalScene = _avoidLabelOverlap(withGrid);

    return SolveResult(scene: finalScene, facts: finalScene.facts, warnings: warnings);
  }

  static FigureScene _dispatch(FigureSpec s) {
    switch (s.type) {
      case FigureType.rect:
        return PlanarBuilder.rect(s);
      case FigureType.square:
        return PlanarBuilder.square(s);
      case FigureType.triangleRight:
        return PlanarBuilder.triangleRight(s);
      case FigureType.triangleGeneral:
        return PlanarBuilder.triangleGeneral(s);
      case FigureType.parallelogram:
        return PlanarBuilder.parallelogram(s);
      case FigureType.trapezoid:
        return PlanarBuilder.trapezoid(s);

      case FigureType.circle:
        return PlanarBuilder.circle(s);
      case FigureType.semicircle:
        return PlanarBuilder.semicircle(s);
      case FigureType.sector:
        return PlanarBuilder.sector(s);
      case FigureType.ring:
        return PlanarBuilder.ring(s);

      case FigureType.compositeRectSemicircle:
        return PlanarBuilder.compositeRectSemicircle(s);
      case FigureType.compositeSquareCircle:
        return PlanarBuilder.compositeSquareCircle(s);

      case FigureType.latticePolygon:
        final poly = LatticeBuilder.generate(
          seed: s.p('seed', 1).toInt(),
          width: s.p('width', 5).toInt(),
          height: s.p('height', 4).toInt(),
        );
        return LatticeBuilder.scene(poly, s);

      case FigureType.leafEstimate:
        return LatticeBuilder.leaf(s);

      case FigureType.cubeNet:
        return SolidBuilder.cubeNet(s);
      case FigureType.cuboidOblique:
        return SolidBuilder.cuboidOblique(s);
      case FigureType.cylinder:
        return SolidBuilder.cylinder(s);
      case FigureType.cone:
        return SolidBuilder.cone(s);

      case FigureType.grid:
        return ChartBuilder.grid(s);
      case FigureType.barChart:
        return ChartBuilder.barChart(s);
      case FigureType.lineChart:
        return ChartBuilder.lineChart(s);
      case FigureType.pieChart:
        return ChartBuilder.pieChart(s);
    }
  }

  static void _validate(FigureScene scene, List<String> warnings) {
    if (scene.extent.isEmpty) {
      throw const FigureSolveError('图形包围盒为空（退化图形）');
    }
    var bad = false;
    for (final s in scene.shapes) {
      for (final p in _shapePoints(s)) {
        if (p.x.isNaN || p.y.isNaN || p.x.isInfinite || p.y.isInfinite) {
          bad = true;
        }
      }
    }
    if (bad) {
      throw const FigureSolveError('求解结果含非法坐标（NaN/Infinity）');
    }

    // 多边形退化检测
    for (final s in scene.shapes) {
      if (s is SPolyline && s.closed && s.pts.length >= 3) {
        final a = Measure.shoelace(s.pts).abs();
        if (a < 1e-6) {
          warnings.add('多边形面积接近 0，可能是退化图形');
        }
        if (!Measure.isSimplePolygon(s.pts)) {
          warnings.add('多边形自交');
        }
      }
    }
  }

  static List<Pt> _shapePoints(Shape s) {
    if (s is SLine) return [s.a, s.b];
    if (s is SPolyline) return s.pts;
    if (s is SCircle) return [s.c - Pt(s.r, s.r), s.c + Pt(s.r, s.r)];
    if (s is SEllipse) return [s.c - Pt(s.rx, s.ry), s.c + Pt(s.rx, s.ry)];
    if (s is SArc) return [s.c - Pt(s.r, s.r), s.c + Pt(s.r, s.r)];
    if (s is SPath) return [s.start, ...s.segs.map((e) => e.p)];
    if (s is SRightAngle) return [s.at];
    return const [];
  }

  static FigureScene _overlayGrid(FigureScene scene, double step) {
    final b = scene.extent;
    final x0 = (b.minX / step).floor() * step;
    final x1 = (b.maxX / step).ceil() * step;
    final y0 = (b.minY / step).floor() * step;
    final y1 = (b.maxY / step).ceil() * step;

    final grid = <Shape>[];
    for (var x = x0; x <= x1 + 1e-9; x += step) {
      grid.add(SLine(Pt(x, y0), Pt(x, y1), LineStyle.thin));
    }
    for (var y = y0; y <= y1 + 1e-9; y += step) {
      grid.add(SLine(Pt(x0, y), Pt(x1, y), LineStyle.thin));
    }
    return FigureScene(
      shapes: [...grid, ...scene.shapes],
      labels: scene.labels,
      dots: scene.dots,
      extent: scene.extent,
      facts: scene.facts,
    );
  }

  /// 标注避让：把挨得太近的标注互相推开。
  ///
  /// 验收标准里明确有"标注是否重叠"这一条，所以这不是锦上添花，是必做项。
  static FigureScene _avoidLabelOverlap(FigureScene scene) {
    final labels = [...scene.labels];
    if (labels.length < 2) return scene;

    const minDist = 0.62;
    for (var iter = 0; iter < 24; iter++) {
      var moved = false;
      for (var i = 0; i < labels.length; i++) {
        for (var j = i + 1; j < labels.length; j++) {
          final a = labels[i];
          final b = labels[j];
          final d = a.at.distTo(b.at);
          if (d >= minDist) continue;
          moved = true;
          final push = d < 1e-6 ? const Pt(0, 1) : (b.at - a.at).unit;
          final delta = (minDist - d) / 2 + 0.01;
          labels[i] = PlacedLabel(a.at - push * delta, a.text, kind: a.kind, offsetDir: a.offsetDir);
          labels[j] = PlacedLabel(b.at + push * delta, b.text, kind: b.kind, offsetDir: b.offsetDir);
        }
      }
      if (!moved) break;
    }
    return FigureScene(
      shapes: scene.shapes,
      labels: labels,
      dots: scene.dots,
      extent: scene.extent,
      facts: scene.facts,
    );
  }
}

class SolveResult {
  final FigureScene scene;
  final FigureFacts facts;

  /// 非致命问题（自交、面积接近 0 等），UI 可据此给出提示。
  final List<String> warnings;

  const SolveResult({required this.scene, required this.facts, required this.warnings});

  bool get clean => warnings.isEmpty;
}
