import 'dart:math' as math;

import '../../core/pt.dart';
import '../../core/rational.dart';
import '../dsl/figure.dart';
import 'measure.dart';

/// 格点不规则图形 / 不规则曲线（树叶估面积）。
///
/// 这是整套方案里性价比最高的一块：小学的"不规则图形"几乎都画在方格纸上、
/// 顶点在格点上。用算法生成 + 本地算面积，答案天然正确，永远不会错。
class LatticeBuilder {
  /// 生成格点多边形（顶点全部落在整数格点上，简单不自交）。
  ///
  /// 生成后必须过两道关：
  ///   1) 自交检测
  ///   2) 鞋带公式 与 Pick 定理 交叉验证（不一致说明图形有问题，直接丢弃重生成）
  static LatticePolygon generate({
    required int seed,
    int width = 5,
    int height = 4,
    LatticeFamily? family,
  }) {
    final rnd = math.Random(seed);
    final f = family ??
        LatticeFamily.values[rnd.nextInt(LatticeFamily.values.length)];

    for (var attempt = 0; attempt < 40; attempt++) {
      final verts = switch (f) {
        LatticeFamily.polyomino => _polyominoBoundary(rnd, width, height),
        LatticeFamily.cornerCut => _cornerCut(rnd, width, height),
      };
      if (verts.length < 3) continue;
      if (!Measure.isSimplePolygon(verts)) continue;

      final shoelace = Measure.shoelaceExact(verts);
      final pick = Measure.pickArea(verts);
      // 两个独立算法必须给出同一个面积
      if ((shoelace.toDouble() - pick).abs() > 1e-6) continue;

      final area = shoelace;
      if (area <= Rational.zero || area > Rational.fromBig(BigInt.from(width * height))) continue;

      return LatticePolygon(vertices: verts, area: area, family: f);
    }
    // 兜底：退化为一个确定的矩形，保证调用方永远拿得到可用图形
    final fallback = <Pt>[
      const Pt(0, 0),
      Pt(width.toDouble(), 0),
      Pt(width.toDouble(), height.toDouble()),
      Pt(0, height.toDouble()),
    ];
    return LatticePolygon(
      vertices: fallback,
      area: Measure.shoelaceExact(fallback),
      family: LatticeFamily.polyomino,
    );
  }

  /// 家族 A：方格块（polyomino）的外边界 —— 正交凹多边形，最适合"数格子"。
  ///
  /// 做法：随机生长出连通的方格集合 → 取只被一个方格拥有的边 → 串成外边界回路。
  /// 面积 = 方格个数，与鞋带公式天然一致。
  static List<Pt> _polyominoBoundary(math.Random rnd, int w, int h) {
    final cells = <Cell>{};
    final target = 2 + rnd.nextInt(math.max(2, w * h - 2));
    final first = Cell(rnd.nextInt(w), rnd.nextInt(h));
    cells.add(first);
    final frontier = <Cell>[first];

    while (cells.length < target && frontier.isNotEmpty) {
      final idx = rnd.nextInt(frontier.length);
      final base = frontier[idx];
      final cand = <Cell>[];
      for (final d in const [(1, 0), (-1, 0), (0, 1), (0, -1)]) {
        final c = Cell(base.x + d.$1, base.y + d.$2);
        if (c.x < 0 || c.y < 0 || c.x >= w || c.y >= h) continue;
        if (cells.contains(c)) continue;
        cand.add(c);
      }
      if (cand.isEmpty) {
        frontier.removeAt(idx);
        continue;
      }
      final pick = cand[rnd.nextInt(cand.length)];
      cells.add(pick);
      frontier.add(pick);
    }

    return traceBoundary(cells);
  }

  /// 追踪方格集合的外边界（逆时针）。
  /// 原理：每个方格贡献 4 条有向边（CCW），被两个方格共享的边会互相抵消，
  /// 剩下的就是外边界。
  static List<Pt> traceBoundary(Set<Cell> cells) {
    final edges = <String, Cell>{};
    for (final c in cells) {
      final corners = <Cell>[
        Cell(c.x, c.y),
        Cell(c.x + 1, c.y),
        Cell(c.x + 1, c.y + 1),
        Cell(c.x, c.y + 1),
      ];
      for (var i = 0; i < 4; i++) {
        final a = corners[i];
        final b = corners[(i + 1) % 4];
        final key = '${a.x},${a.y}->${b.x},${b.y}';
        final rev = '${b.x},${b.y}->${a.x},${a.y}';
        if (edges.containsKey(rev)) {
          edges.remove(rev);
        } else {
          edges[key] = a;
        }
      }
    }
    if (edges.isEmpty) return const [];

    final adj = <Cell, List<Cell>>{};
    edges.forEach((key, a) {
      final parts = key.split('->');
      final bp = parts[1].split(',');
      final b = Cell(int.parse(bp[0]), int.parse(bp[1]));
      adj.putIfAbsent(a, () => []).add(b);
    });

    final start = adj.keys.first;
    final path = <Cell>[start];
    var cur = start;
    var prev = Cell(start.x - 1, start.y - 1); // 哨兵，不可能等于任何合法邻居
    for (var step = 0; step < 1000; step++) {
      final nexts = adj[cur] ?? const [];
      if (nexts.isEmpty) break;
      Cell next = nexts.first;
      if (nexts.length > 1 && nexts[1] != prev) next = nexts[1];
      if (next == start) break;
      path.add(next);
      prev = cur;
      cur = next;
    }
    return path.map((c) => Pt(c.x.toDouble(), c.y.toDouble())).toList();
  }

  /// 家族 B：矩形切角 —— 带斜边的凹/凸多边形，斜边顶点仍在格点上。
  ///
  /// 关键约束：切掉的量必须小于所在边的一半，且两个被切的角不能相邻冲突，
  /// 否则切出来的两条斜边会相交。
  static List<Pt> _cornerCut(math.Random rnd, int w, int h) {
    final W = w.toDouble();
    final H = h.toDouble();

    // 左下角切：沿底边切 k，沿左边切 m
    final k = (1 + rnd.nextInt(math.max(1, (w / 2).floor()))).toDouble();
    final m = (1 + rnd.nextInt(math.max(1, (h / 2).floor()))).toDouble();

    final verts = <Pt>[
      Pt(k, 0),
      Pt(W, 0),
      Pt(W, H),
      Pt(0, H),
    ];
    // 是否再切右上角
    if (rnd.nextBool() && w >= 4 && h >= 3) {
      final k2 = (1 + rnd.nextInt(math.max(1, (w / 2).floor()))).toDouble();
      final m2 = (1 + rnd.nextInt(math.max(1, (h / 2).floor()))).toDouble();
      if (k + k2 < W && m + m2 < H) {
        verts.insert(2, Pt(W - k2, H));
        verts.insert(3, Pt(W, H - m2));
        verts.removeAt(3); // 去掉原来的 (W,H)
      }
    }
    verts.add(Pt(0, m));
    return verts;
  }

  /// 把格点多边形渲染成场景（强制画方格纸）。
  static FigureScene scene(LatticePolygon poly, FigureSpec s) {
    final verts = poly.vertices;
    final box = Box2.fromPoints(verts);
    final shapes = <Shape>[];

    // 方格纸：必须画，否则"数格子"无从谈起
    final x0 = box.minX.floor().toDouble();
    final x1 = box.maxX.ceil().toDouble();
    final y0 = box.minY.floor().toDouble();
    final y1 = box.maxY.ceil().toDouble();
    for (var x = x0; x <= x1 + 1e-9; x += s.gridStep) {
      shapes.add(SLine(Pt(x, y0), Pt(x, y1), LineStyle.thin));
    }
    for (var y = y0; y <= y1 + 1e-9; y += s.gridStep) {
      shapes.add(SLine(Pt(x0, y), Pt(x1, y), LineStyle.thin));
    }

    // 多边形边界必须用粗线：正交多边形的边与网格线重合，
    // 同为细线时视觉上完全不可辨（图看起来就是"一张空网格"）。
    shapes.add(SPolyline(verts,
        closed: true, style: LineStyle.bold, fill: s.shade ? FillStyle.shade : FillStyle.none));

    final labels = <PlacedLabel>[];
    if (s.text.containsKey('hint')) {
      labels.add(PlacedLabel(Pt(box.center.x, box.maxY + 0.6), s.t('hint', ''), kind: LabelKind.note));
    }

    return FigureScene(
      shapes: shapes,
      labels: labels,
      dots: verts,
      extent: box,
      facts: FigureFacts({
        'area': Quantity.num(poly.area, unit: '平方${unitName(s.unit)}'),
        'perimeter': Quantity(approx: Measure.perimeter(verts), unit: unitName(s.unit)),
        'cells': Quantity.num(poly.area, unit: '格'),
      }),
    );
  }

  /// 树叶等不规则曲线：固定控制点的三次贝塞尔模板 + 仿射变形。
  ///
  /// 刻意不用随机椭圆 —— 教学意图恰恰是"不能精确计算，只能估"。
  /// 所以只需"看起来像树叶"，但必须压在方格纸上让孩子真的能数格子。
  static FigureScene leaf(FigureSpec s) {
    final seed = s.p('seed', 1).toInt();
    final scale = s.p('scale', 3).toDouble();
    final rnd = math.Random(seed);

    // 固定模板：一个上尖下圆的叶片轮廓（单位尺度）
    const tmpl = [
      (c1: (0.05, 0.55), c2: (0.30, 0.95), p: (0.50, 1.00)),
      (c1: (0.70, 0.95), c2: (0.95, 0.55), p: (1.00, 0.30)),
      (c1: (1.05, 0.10), c2: (0.85, -0.05), p: (0.50, 0.00)),
      (c1: (0.15, -0.05), c2: (-0.05, 0.10), p: (0.00, 0.30)),
    ];

    // 仿射变形：拉伸 + 旋转 + 镜像 + 轻微扰动
    final sx = scale * (0.85 + rnd.nextDouble() * 0.3);
    final sy = scale * (0.85 + rnd.nextDouble() * 0.3);
    final rot = (rnd.nextDouble() - 0.5) * 0.5;
    final mirror = rnd.nextBool() ? -1.0 : 1.0;

    Pt xf(double u, double v) {
      var x = u * sx * mirror;
      var y = v * sy;
      final c = math.cos(rot);
      final sn = math.sin(rot);
      return Pt(x * c - y * sn, x * sn + y * c);
    }

    final start = xf(0.0, 0.30);
    final segs = <CubicSeg>[];
    for (final t in tmpl) {
      segs.add(CubicSeg(xf(t.c1.$1, t.c1.$2), xf(t.c2.$1, t.c2.$2), xf(t.p.$1, t.p.$2)));
    }

    final shapes = <Shape>[];
    final box = Box2.fromPoints([start, ...segs.map((e) => e.p)]);

    // 方格纸
    final x0 = box.minX.floor().toDouble();
    final x1 = box.maxX.ceil().toDouble();
    final y0 = box.minY.floor().toDouble();
    final y1 = box.maxY.ceil().toDouble();
    for (var x = x0; x <= x1 + 1e-9; x += s.gridStep) {
      shapes.add(SLine(Pt(x, y0), Pt(x, y1), LineStyle.thin));
    }
    for (var y = y0; y <= y1 + 1e-9; y += s.gridStep) {
      shapes.add(SLine(Pt(x0, y), Pt(x1, y), LineStyle.thin));
    }
    shapes.add(SPath(start, segs, closed: true, fill: s.shade ? FillStyle.hatch : FillStyle.none));

    return FigureScene(
      shapes: shapes,
      labels: const [],
      dots: const [],
      extent: box,
      facts: FigureFacts({
        // 估面积没有精确答案，只给出包围盒面积作为上界参考
        'boundingArea': Quantity(approx: box.w * box.h, unit: '平方${unitName(s.unit)}'),
      }),
    );
  }
}

enum LatticeFamily { polyomino, cornerCut }

class LatticePolygon {
  final List<Pt> vertices;
  final Rational area;
  final LatticeFamily family;

  const LatticePolygon({required this.vertices, required this.area, required this.family});

  int get vertexCount => vertices.length;
}

/// 整数格点（内部用）。
class Cell {
  final int x;
  final int y;

  const Cell(this.x, this.y);

  @override
  bool operator ==(Object other) => other is Cell && other.x == x && other.y == y;

  @override
  int get hashCode => Object.hash(x, y);

  @override
  String toString() => '($x,$y)';
}
