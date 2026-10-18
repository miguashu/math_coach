import 'dart:math' as math;

import '../../core/pt.dart';
import '../../core/rational.dart';
import '../dsl/figure.dart';
import 'lattice.dart';
import 'measure.dart';

/// 立体图形与展开图。
///
/// 立体图形的圆在斜二测画法里是**椭圆而非正圆**，必须由渲染器按透视比例画；
/// 圆锥的轮廓线是两条外公切线，**必须用解析公式算**，不能交给模型猜 ——
/// 这正是"必须本地求解"的原因。
class SolidBuilder {
  /// 圆柱：上下底椭圆 + 两条母线。
  static FigureScene cylinder(FigureSpec s) {
    final r = s.p('r', 2).toDouble();
    final h = s.p('h', 5).toDouble();
    final rx = r;
    final ry = r * _depthRatio; // 斜二测：深度方向压缩

    final top = Pt(0, h);
    final bottom = Pt.zero;

    final shapes = <Shape>[
      SEllipse(top, rx, ry),
      SEllipse(bottom, rx, ry, style: LineStyle.dashed),
      SLine(Pt(-rx, 0), Pt(-rx, h)),
      SLine(Pt(rx, 0), Pt(rx, h)),
    ];
    // 下底只画前半弧（虚线表示被遮挡），这里用两段弧近似
    final labels = <PlacedLabel>[
      PlacedLabel(Pt(rx + 0.45, h / 2), s.t('h', '${_n(h)} ${s.unit}'), kind: LabelKind.length),
      PlacedLabel(Pt(0, -0.55), s.t('r', 'r = ${_n(r)} ${s.unit}'), kind: LabelKind.length),
    ];
    final pts = [Pt(-rx, 0), Pt(rx, h + ry)];

    return FigureScene(
      shapes: shapes,
      labels: labels,
      dots: const [],
      extent: Box2.fromPoints(pts),
      facts: FigureFacts({
        'volume': Measure.cylinderVolume(r, h, s.unit),
        'surface': Measure.cylinderSurface(r, h, s.unit),
        'baseArea': Measure.circleArea(r, s.unit),
      }),
    );
  }

  /// 圆锥：底椭圆 + 两条外公切线 + 顶点。
  ///
  /// 切线解析解：椭圆 x²/rx² + y²/ry² = 1，外点 (0, H)（相对椭圆中心）。
  /// 切点满足切线过外点 → y0 = ry²/H，x0 = ±rx·√(1 − y0²/ry²)。
  /// 只有 H > ry 时切线存在。
  static FigureScene cone(FigureSpec s) {
    final r = s.p('r', 2).toDouble();
    final h = s.p('h', 5).toDouble();
    final rx = r;
    final ry = r * _depthRatio;
    final apex = Pt(0, h);

    final shapes = <Shape>[SEllipse(Pt.zero, rx, ry)];

    Pt? tL;
    Pt? tR;
    if (h > ry) {
      final y0 = ry * ry / h;
      final x0 = rx * math.sqrt(1 - (y0 * y0) / (ry * ry));
      tL = Pt(-x0, y0);
      tR = Pt(x0, y0);
      shapes.add(SLine(apex, tL));
      shapes.add(SLine(apex, tR));
    } else {
      // 高度不足（视觉上切线不存在），退化成连到椭圆两端，但仍标注为近似
      tL = Pt(-rx, 0);
      tR = Pt(rx, 0);
      shapes.add(SLine(apex, tL));
      shapes.add(SLine(apex, tR));
    }

    final labels = <PlacedLabel>[
      PlacedLabel(Pt(0.35, h / 2), s.t('h', '${_n(h)} ${s.unit}'), kind: LabelKind.length),
      PlacedLabel(Pt(0, -0.6), s.t('r', 'r = ${_n(r)} ${s.unit}'), kind: LabelKind.length),
    ];
    final pts = [Pt(-rx, -ry), apex];

    return FigureScene(
      shapes: shapes,
      labels: labels,
      dots: [apex],
      extent: Box2.fromPoints(pts),
      facts: FigureFacts({
        'volume': Measure.coneVolume(r, h, s.unit),
        'baseArea': Measure.circleArea(r, s.unit),
      }),
    );
  }

  /// 长方体斜二测图：正面矩形 + 顶面平行四边形 + 侧面平行四边形。
  ///
  /// 参数键 w/h/d 分别对应 长（底面）/ 高 / 宽（进深）；
  /// a/b/c 是旧版出题器用过的别名，仍然接受 —— 错题本里存着老 spec，
  /// 重放时不认别名就又变回默认尺寸的图形。
  ///
  /// 12 条棱一次画全：剪影 6 条（实线）+ 正面另 2 条 + 顶面右缘（实线）
  /// + 被挡住的 3 条（虚线）。曾经只画剪影加两条**面的对角线**，
  /// 正面矩形都没闭合 —— 图形和题面对不上就是这么来的。
  static FigureScene cuboidOblique(FigureSpec s) {
    final w = s.p('w', s.p('a', 5)).toDouble();
    final h = s.p('h', s.p('c', 3)).toDouble();
    final d = s.p('d', s.p('b', 2)).toDouble();
    final dx = d * _depthRatio * math.cos(_depthAngle);
    final dy = d * _depthRatio * math.sin(_depthAngle);

    final A = const Pt(0, 0); // 前·左下
    final B = Pt(w, 0); // 前·右下
    final C = Pt(w, h); // 前·右上
    final D = Pt(0, h); // 前·左上
    final E = D + Pt(dx, dy); // 后·左上
    final F = C + Pt(dx, dy); // 后·右上
    final G = B + Pt(dx, dy); // 后·右下
    final H = A + Pt(dx, dy); // 后·左下（整条棱都被挡住，只出现在虚线里）

    final shapes = <Shape>[
      // 剪影六边形：前底棱 → 右深棱 → 后右竖棱 → 后顶棱 → 左深棱 → 前左竖棱
      SPolyline([A, B, G, F, E, D], closed: true),
      // 正面矩形补全（左竖棱、底棱已在剪影里）
      SLine(B, C),
      SLine(C, D),
      // 顶面右缘（顶面另两条边已在剪影里）
      SLine(C, F),
      // 被挡住的三条棱：后左竖棱、底面左深棱、底面后棱
      SLine(E, H, LineStyle.dashed),
      SLine(H, A, LineStyle.dashed),
      SLine(H, G, LineStyle.dashed),
    ];
    final labels = <PlacedLabel>[
      PlacedLabel(Pt(w / 2, -0.5), s.t('w', '${_n(w)} ${s.unit}'), kind: LabelKind.length),
      PlacedLabel(Pt(-0.55, h / 2), s.t('h', '${_n(h)} ${s.unit}'), kind: LabelKind.length),
      PlacedLabel(Pt(w + dx * 0.5 + 0.35, dy * 0.5), s.t('d', '${_n(d)} ${s.unit}'), kind: LabelKind.length),
    ];
    final pts = [A, B, C, D, E, F, G]; // H 在剪影内部，不影响包围盒

    return FigureScene(
      shapes: shapes,
      labels: labels,
      dots: const [],
      extent: Box2.fromPoints(pts),
      facts: FigureFacts({
        'volume': Measure.cuboidVolume(w, h, d, s.unit),
        'surface': Measure.cuboidSurface(w, h, d, s.unit),
      }),
    );
  }

  /// 正方体展开图：网格 + 折线。
  /// 渲染前必须先过 `CubeNetValidator` —— 否则画出来的展开图可能根本折不起来。
  static FigureScene cubeNet(FigureSpec s) {
    final layout = s.t('layout', 'cross');
    final net = CubeNet.byName(layout) ?? CubeNet.cross;
    final edge = s.p('edge', 1).toDouble();

    final cells = net.cells;
    final shapes = <Shape>[];
    for (final c in cells) {
      shapes.add(SPolyline([
        Pt(c.x * edge, c.y * edge),
        Pt((c.x + 1) * edge, c.y * edge),
        Pt((c.x + 1) * edge, (c.y + 1) * edge),
        Pt(c.x * edge, (c.y + 1) * edge),
      ], closed: true));
    }
    final labels = <PlacedLabel>[
      for (final c in cells)
        PlacedLabel(Pt((c.x + 0.5) * edge, (c.y + 0.5) * edge),
            s.text['face_${c.x}_${c.y}'] ?? '', kind: LabelKind.note),
    ];

    // 棱长标注：放在最下面一行最左那格的底边下方。
    // 只在 spec 明确带了 edge 参数时画 —— 老错题重放的 spec 没有这个参数，
    // 那时题面棱长是多少已无从恢复，宁可不标也不能标个错的。
    if (s.pOrNull('edge') != null) {
      Cell base = cells.first;
      for (final c in cells) {
        if (c.y < base.y || (c.y == base.y && c.x < base.x)) base = c;
      }
      labels.add(PlacedLabel(
        Pt((base.x + 0.5) * edge, base.y * edge - 0.45),
        s.t('edge', '${_n(edge)} ${s.unit}'),
        kind: LabelKind.length,
      ));
    }

    final pts = <Pt>[
      for (final c in cells) ...[Pt(c.x * edge, c.y * edge), Pt((c.x + 1) * edge, (c.y + 1) * edge)],
    ];

    final ok = CubeNetValidator.isFoldable(net);
    return FigureScene(
      shapes: shapes,
      labels: labels.where((l) => l.text.isNotEmpty).toList(),
      dots: const [],
      extent: Box2.fromPoints(pts),
      facts: FigureFacts({
        'foldable': Quantity(approx: ok ? 1 : 0),
        'faceCount': Quantity.num(Rational(net.cells.length)),
      }),
    );
  }
}

/// 斜二测画法的深度压缩比与角度。
const double _depthRatio = 0.5;
const double _depthAngle = math.pi / 4; // 45°

String _n(double v) {
  if ((v - v.roundToDouble()).abs() < 1e-9) return v.round().toString();
  final s = v.toStringAsFixed(2);
  return s.replaceAll(RegExp(r'0+$'), '').replaceAll(RegExp(r'\.$'), '');
}

/// ────────────────────────────────────────────────────────────
/// 正方体展开图
/// ────────────────────────────────────────────────────────────

class CubeNet {
  final String name;
  final List<Cell> cells;

  const CubeNet(this.name, this.cells);

  /// 经典"十字"展开图（1-4-1 型）。
  static final CubeNet cross = CubeNet('cross', [
    const Cell(1, 0),
    const Cell(0, 1),
    const Cell(1, 1),
    const Cell(2, 1),
    const Cell(3, 1),
    const Cell(1, 2),
  ]);

  /// 长条 1-4-1（一排在中间，上下各一）。
  static final CubeNet stair = CubeNet('stair', [
    const Cell(0, 0),
    const Cell(0, 1),
    const Cell(1, 1),
    const Cell(2, 1),
    const Cell(3, 1),
    const Cell(3, 2),
  ]);

  /// 2-2-2 型（楼梯状）。
  static final CubeNet zigzag = CubeNet('zigzag', [
    const Cell(0, 0),
    const Cell(1, 0),
    const Cell(1, 1),
    const Cell(2, 1),
    const Cell(2, 2),
    const Cell(3, 2),
  ]);

  /// 3-3 型。
  static final CubeNet twin = CubeNet('twin', [
    const Cell(0, 0),
    const Cell(1, 0),
    const Cell(2, 0),
    const Cell(2, 1),
    const Cell(3, 1),
    const Cell(4, 1),
  ]);

  /// 2×3 矩形：整整齐齐反而折不成（折到一半两个面叠上）。
  static final CubeNet rect23 = CubeNet('rect23', [
    const Cell(0, 0),
    const Cell(1, 0),
    const Cell(2, 0),
    const Cell(0, 1),
    const Cell(1, 1),
    const Cell(2, 1),
  ]);

  /// 四个一排、两片折向同一边：两片都抢当"顶"，底面空着。
  static final CubeNet twotop = CubeNet('twotop', [
    const Cell(0, 0),
    const Cell(1, 0),
    const Cell(2, 0),
    const Cell(3, 0),
    const Cell(0, 1),
    const Cell(3, 1),
  ]);

  /// 可折叠的内置展开图（表面积等"正经"题只能用这些）。
  static final List<CubeNet> builtin = [cross, stair, zigzag, twin];

  /// 折不起来的"陷阱"展开图：判断题必须混着出 ——
  /// 池子里全是可折的话，孩子无脑答"能"就能拿满分。
  static final List<CubeNet> traps = [rect23, twotop];

  static final List<CubeNet> all = [...builtin, ...traps];

  static CubeNet? byName(String name) {
    for (final n in all) {
      if (n.name == name) return n;
    }
    return null;
  }
}

/// 展开图折叠校验器。
///
/// 这不是"看起来像不像"的检查，而是真正的三维折叠模拟：
/// 用 BFS 从基准面出发，每跨过一条公共边就把坐标框架绕该边旋转 −90°，
/// 最后检查 6 个面是否恰好落在立方体 6 个不同面上（落重了就折不起来）。
///
/// 全程用整数向量，无浮点误差。
class CubeNetValidator {
  /// 说明坐标系：立方体边长为 2、中心在原点，六个面心即 ±1 的轴向向量。
  /// 立方体的六个面心（边长 2、中心在原点）。
  static const _cubeFaces = <Vec3>[
    Vec3(1, 0, 0),
    Vec3(-1, 0, 0),
    Vec3(0, 1, 0),
    Vec3(0, -1, 0),
    Vec3(0, 0, 1),
    Vec3(0, 0, -1),
  ];

  static bool isFoldable(CubeNet net) {
    final cells = net.cells;
    if (cells.length != 6) return false;
    if (cells.toSet().length != 6) return false; // 有重叠面
    if (!_isEdgeConnected(cells)) return false;

    final index = {for (var i = 0; i < cells.length; i++) cells[i]: i};

    // 每个面的框架：u, v, n 三个整数正交向量；center 为 3D 面心
    final frames = List<_Frame?>.filled(6, null);
    final centers = List<Vec3?>.filled(6, null);

    frames[0] = _Frame(Vec3(1, 0, 0), Vec3(0, 1, 0), Vec3(0, 0, 1));
    centers[0] = Vec3(0, 0, 1);

    final queue = <int>[0];
    final seen = <int>{0};

    while (queue.isNotEmpty) {
      final ci = queue.removeAt(0);
      final f = frames[ci]!;
      final cc = centers[ci]!;
      final cell = cells[ci];

      for (final d in const [(1, 0), (-1, 0), (0, 1), (0, -1)]) {
        final nb = Cell(cell.x + d.$1, cell.y + d.$2);
        final ni = index[nb];
        if (ni == null) continue;

        // 行进方向（3D，单位向量）：dx*u + dy*v
        final du = f.u * d.$1 + f.v * d.$2;
        final axis = du.cross(f.n); // 铰链轴方向

        // 折叠：把 B 面（平铺时与 A 同向）绕铰链转 −90°。
        // 关键关系是 R(du) = −n_A：平铺时指向 B 的方向，折起来后指向"背离 A 外法线"。
        // 注意旋转的是 B，不是 A —— 用 (A.center − edgeMid) 去转是错的。
        final nf = _Frame(
          _fold(f.u, axis),
          _fold(f.v, axis),
          _fold(f.n, axis),
        );

        final edgeMid = cc + du; // 半边长 = 1
        final nc = edgeMid + _fold(du, axis);

        if (frames[ni] == null) {
          frames[ni] = nf;
          centers[ni] = nc;
          seen.add(ni);
          queue.add(ni);
        } else {
          // 关键：网格里有环时（比如 2×3 矩形），同一个面会经由两条路径得到结果。
          // 两条路径必须自洽，否则说明折起来会撞在一起。
          if (centers[ni] != nc) return false;
          if (frames[ni]!.n != nf.n) return false;
        }
      }
    }

    if (seen.length != 6) return false;

    // 6 个面心必须恰好是立方体的 6 个面 —— 不能只是"互不相同"，
    // 否则展开图飘在立方体外面也会被判成可折叠。
    final occupied = <String>{for (final c in centers) c!.key};
    if (occupied.length != 6) return false;
    for (final face in _cubeFaces) {
      if (!occupied.contains(face.key)) return false;
    }
    return true;
  }

  static bool _isEdgeConnected(List<Cell> cells) {
    if (cells.isEmpty) return false;
    final set = cells.toSet();
    final start = cells.first;
    final seen = <Cell>{start};
    final queue = <Cell>[start];
    while (queue.isNotEmpty) {
      final cur = queue.removeAt(0);
      for (final d in const [(1, 0), (-1, 0), (0, 1), (0, -1)]) {
        final nb = Cell(cur.x + d.$1, cur.y + d.$2);
        if (!set.contains(nb) || seen.contains(nb)) continue;
        seen.add(nb);
        queue.add(nb);
      }
    }
    return seen.length == cells.length;
  }

  /// 折叠旋转：绕铰链轴 axis 转 −90°（Rodrigues，cos=0, sin=−1）：
  ///   w' = −(axis × w) + axis·(axis·w)
  ///
  /// 手算校验（顶面 A=(0,0,1)、法线 +z，向 +u 折）：
  ///   铰链轴 axis = du×n = (0,−1,0)
  ///   R(du) = −(axis×du) = (0,0,−1) = −n_A ✓
  ///   B 面心 = edgeMid + R(du) = (1,0,1)+(0,0,−1) = (1,0,0) → 右侧面 ✓
  ///   R(n_A) = (1,0,0) → 正是右侧面的外法线 ✓
  static Vec3 _fold(Vec3 w, Vec3 axis) {
    return (axis.cross(w) * -1) + axis * axis.dot(w);
  }
}

class _Frame {
  final Vec3 u;
  final Vec3 v;
  final Vec3 n;

  const _Frame(this.u, this.v, this.n);
}

class Vec3 {
  final int x;
  final int y;
  final int z;

  const Vec3(this.x, this.y, this.z);

  Vec3 operator +(Vec3 o) => Vec3(x + o.x, y + o.y, z + o.z);
  Vec3 operator -(Vec3 o) => Vec3(x - o.x, y - o.y, z - o.z);
  Vec3 operator *(int k) => Vec3(x * k, y * k, z * k);

  int dot(Vec3 o) => x * o.x + y * o.y + z * o.z;

  Vec3 cross(Vec3 o) => Vec3(
        y * o.z - z * o.y,
        z * o.x - x * o.z,
        x * o.y - y * o.x,
      );

  String get key => '$x,$y,$z';

  /// 必须实现值相等：折叠校验要靠"面心是否重合"来判断有没有撞面，
  /// 走对象身份比较会把每个已访问的邻面都误判成冲突。
  @override
  bool operator ==(Object other) => other is Vec3 && x == other.x && y == other.y && z == other.z;

  @override
  int get hashCode => Object.hash(x, y, z);

  @override
  String toString() => '($x,$y,$z)';
}
