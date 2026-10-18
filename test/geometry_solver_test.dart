import 'dart:math' as math;

import 'package:test/test.dart';
import 'package:math_coach/core/pt.dart';
import 'package:math_coach/core/rational.dart';
import 'package:math_coach/geometry/dsl/figure.dart';
import 'package:math_coach/geometry/solver/lattice.dart';
import 'package:math_coach/geometry/solver/measure.dart';
import 'package:math_coach/geometry/solver/planar.dart';
import 'package:math_coach/geometry/solver/solid.dart';
import 'package:math_coach/geometry/solver/solver.dart';
import 'package:math_coach/quiz/generator.dart';

void main() {
  group('验收用例 1：圆的半径/直径/圆心', () {
    test('半径线从圆心指向圆周，d 严格等于 2r', () {
      final r = FigureSolver.solve(FigureSpec(type: FigureType.circle, params: {'r': 3}));
      final circle = r.scene.shapes.whereType<SCircle>().first;
      expect(circle.c, const Pt(0, 0));

      // 半径线：一端必须是圆心
      final bold = r.scene.shapes.whereType<SLine>().where((l) => l.style == LineStyle.bold).first;
      expect(bold.a, const Pt(0, 0));
      // 另一端必须落在圆周上
      expect(bold.b.distTo(circle.c), closeTo(3, 1e-9));

      // 直径线：穿过圆心，长度 = 2r
      final dashed = r.scene.shapes.whereType<SLine>().where((l) => l.style == LineStyle.dashed).first;
      expect(dashed.a.distTo(dashed.b), closeTo(6, 1e-9));
      expect(dashed.a + dashed.b, const Pt(0, 0)); // 中点为圆心

      // 标注文字里 d 必须是 2r
      final dLabel = r.scene.labels.firstWhere((l) => l.text.startsWith('d ='));
      expect(dLabel.text, contains('6'));
    });

    test('答案本地算：面积 9π、周长 6π', () {
      final r = FigureSolver.solve(FigureSpec(type: FigureType.circle, params: {'r': 3}));
      expect(r.facts['area']!.display, '9π 平方厘米');
      expect(r.facts['circumference']!.display, '6π 厘米');
    });
  });

  group('验收用例 2：扇形与圆心角', () {
    test('圆心角标注落在扇形内部', () {
      final r = FigureSolver.solve(FigureSpec(
        type: FigureType.sector,
        params: {'r': 3, 'angleDeg': 120},
      ));
      final angleLabel = r.scene.labels.firstWhere((l) => l.kind == LabelKind.angle);
      // 标注点必须在圆内，且在两条半径夹角范围内
      expect(angleLabel.at.len, lessThan(3));
      final deg = Ang.deg(math.atan2(angleLabel.at.y, angleLabel.at.x));
      expect(deg, greaterThan(0));
      expect(deg, lessThan(120));
    });

    test('扇区角度之和为 360°（扇形统计图）', () {
      final r = FigureSolver.solve(FigureSpec(
        type: FigureType.pieChart,
        lists: {
          'values': [10, 20, 30, 40]
        },
        strs: {
          'labels': ['A', 'B', 'C', 'D']
        },
      ));
      var sum = 0.0;
      for (final s in r.scene.shapes.whereType<SArc>()) {
        sum += Ang.deg(s.sweep);
      }
      expect(sum, closeTo(360, 1e-6));
    });
  });

  group('验收用例 3：格点不规则多边形', () {
    test('顶点严格落在整数格点上', () {
      for (var seed = 1; seed <= 30; seed++) {
        final poly = LatticeBuilder.generate(seed: seed, width: 5, height: 4);
        for (final v in poly.vertices) {
          expect(v.x, closeTo(v.x.roundToDouble(), 1e-9), reason: 'seed=$seed x=${v.x}');
          expect(v.y, closeTo(v.y.roundToDouble(), 1e-9), reason: 'seed=$seed y=${v.y}');
        }
      }
    });

    test('鞋带公式与 Pick 定理必须一致（交叉验证）', () {
      for (var seed = 1; seed <= 30; seed++) {
        final poly = LatticeBuilder.generate(seed: seed, width: 5, height: 4);
        final shoelace = Measure.shoelace(poly.vertices).abs();
        final pick = Measure.pickArea(poly.vertices);
        expect(shoelace, closeTo(pick, 1e-6), reason: 'seed=$seed 鞋带=$shoelace Pick=$pick');
      }
    });

    test('生成的图形必须简单（不自交）且不退化', () {
      for (var seed = 1; seed <= 30; seed++) {
        final poly = LatticeBuilder.generate(seed: seed, width: 5, height: 4);
        expect(Measure.isSimplePolygon(poly.vertices), isTrue, reason: 'seed=$seed 自交');
        expect(poly.area > Rational.zero, isTrue, reason: 'seed=$seed 面积为 0');
      }
    });

    test('场景自带正确答案，且标注了方格纸', () {
      final r = FigureSolver.solve(FigureSpec(
        type: FigureType.latticePolygon,
        params: {'seed': 7, 'width': 5, 'height': 4},
      ));
      expect(r.facts['area'], isNotNull);
      // 方格纸：横线 + 竖线数量必须足够多
      final thin = r.scene.shapes.whereType<SLine>().where((l) => l.style == LineStyle.thin).length;
      expect(thin, greaterThanOrEqualTo(8));
    });
  });

  group('验收用例 4：组合图形（矩形 + 半圆）', () {
    test('半圆直径严格等于矩形上边', () {
      final r = FigureSolver.solve(FigureSpec(
        type: FigureType.compositeRectSemicircle,
        params: {'w': 6, 'h': 4},
      ));
      final arc = r.scene.shapes.whereType<SArc>().first;
      expect(arc.r, closeTo(3, 1e-9)); // 直径 6 → 半径 3
      // 半圆圆心必须在矩形上边的中点
      expect(arc.c, const Pt(3, 4));
    });

    test('面积 = 矩形 + 半圆，本地算', () {
      final r = FigureSolver.solve(FigureSpec(
        type: FigureType.compositeRectSemicircle,
        params: {'w': 6, 'h': 4},
      ));
      expect(r.facts['rectArea']!.display, '24 平方厘米');
      expect(r.facts['semicircleArea']!.display, '4.5π 平方厘米');
      // 6*4 + 0.5*π*3² ≈ 24 + 14.137 = 38.137
      expect(r.facts['area']!.approx, closeTo(38.137, 0.01));
    });
  });

  group('验收用例 5：正方体展开图', () {
    test('内置展开图都能折成正方体（本地校验通过）', () {
      for (final net in CubeNet.builtin) {
        expect(CubeNetValidator.isFoldable(net), isTrue, reason: '${net.name} 折不起来');
      }
    });

    test('6 个面互不重叠', () {
      for (final net in CubeNet.builtin) {
        expect(net.cells.toSet().length, 6, reason: '${net.name} 有重叠面');
      }
    });

    test('已知折不起来的形状必须被判否：2×3 矩形', () {
      final bad = CubeNet('bad_rect', [
        const Cell(0, 0),
        const Cell(1, 0),
        const Cell(2, 0),
        const Cell(0, 1),
        const Cell(1, 1),
        const Cell(2, 1),
      ]);
      expect(CubeNetValidator.isFoldable(bad), isFalse);
    });

    test('已知折不起来的形状必须被判否：1×6 长条', () {
      final bad = CubeNet('bad_strip', [
        const Cell(0, 0),
        const Cell(1, 0),
        const Cell(2, 0),
        const Cell(3, 0),
        const Cell(4, 0),
        const Cell(5, 0),
      ]);
      expect(CubeNetValidator.isFoldable(bad), isFalse);
    });

    test('重复面必须被判否', () {
      final dup = CubeNet('dup', [
        const Cell(0, 0),
        const Cell(0, 0),
        const Cell(1, 0),
        const Cell(2, 0),
        const Cell(3, 0),
        const Cell(4, 0),
      ]);
      expect(CubeNetValidator.isFoldable(dup), isFalse);
    });

    test('陷阱布局（折不起来）必须被判否，且能按名字取回', () {
      // 判断题要一半可折一半不可折 —— 池子里全是可折的话，
      // 孩子无脑答"能"就能全对（M13 复查发现的死分支）。
      expect(CubeNet.traps.length, 2);
      for (final net in CubeNet.traps) {
        expect(CubeNetValidator.isFoldable(net), isFalse,
            reason: '${net.name} 明明折得起来，当不了陷阱题');
        expect(CubeNet.byName(net.name), same(net));
        expect(net.cells.toSet().length, 6);
      }
      // builtin 里的仍然全部可折
      for (final net in CubeNet.builtin) {
        expect(CubeNet.byName(net.name), same(net));
      }
    });
  });

  group('验收用例 6/7：立体图形', () {
    test('圆柱上下底是椭圆（斜二测），母线等长于高', () {
      final r = FigureSolver.solve(FigureSpec(
        type: FigureType.cylinder,
        params: {'r': 2, 'h': 5},
      ));
      final ells = r.scene.shapes.whereType<SEllipse>().toList();
      expect(ells.length, 2);
      expect(ells.first.rx, closeTo(2, 1e-9));
      // 斜二测：深度方向压缩，所以 ry < rx
      expect(ells.first.ry, lessThan(ells.first.rx));

      final verts = r.scene.shapes
          .whereType<SLine>()
          .where((l) => (l.a.x - l.b.x).abs() < 1e-9)
          .toList();
      expect(verts.length, 2);
      for (final v in verts) {
        expect(v.a.distTo(v.b), closeTo(5, 1e-9));
      }
    });

    test('圆锥轮廓线必须与底面椭圆相切（切线由解析公式算出，不能目测）', () {
      final r = FigureSolver.solve(FigureSpec(
        type: FigureType.cone,
        params: {'r': 2, 'h': 5},
      ));
      final ellipse = r.scene.shapes.whereType<SEllipse>().first;
      final rx = ellipse.rx;
      final ry = ellipse.ry;
      final apex = Pt(0, 5);

      final lines = r.scene.shapes.whereType<SLine>().toList();
      expect(lines.length, 2);
      for (final l in lines) {
        final t = l.a == apex ? l.b : l.a; // 切点（另一端是顶点）
        // 1) 切点必须在椭圆上
        final onEllipse = (t.x * t.x) / (rx * rx) + (t.y * t.y) / (ry * ry);
        expect(onEllipse, closeTo(1, 1e-9));
        // 2) 切线方程 (x·x0)/rx² + (y·y0)/ry² = 1 必须过顶点
        final throughApex = (apex.x * t.x) / (rx * rx) + (apex.y * t.y) / (ry * ry);
        expect(throughApex, closeTo(1, 1e-9));
      }
      // 左右对称
      expect(lines[0].a.x + lines[1].a.x + lines[0].b.x + lines[1].b.x, closeTo(0, 1e-9));
    });

    test('长方体斜二测：体积与表面积本地算', () {
      final r = FigureSolver.solve(FigureSpec(
        type: FigureType.cuboidOblique,
        params: {'w': 5, 'h': 3, 'd': 2},
      ));
      expect(r.facts['volume']!.display, '30 立方厘米');
      expect(r.facts['surface']!.display, '62 平方厘米');
    });

    test('长方体斜二测：12 条棱画全、不许有对角线、隐藏棱用虚线', () {
      final r = FigureSolver.solve(FigureSpec(
        type: FigureType.cuboidOblique,
        params: {'w': 5, 'h': 3, 'd': 2},
      ));
      final s2 = math.sqrt2 / 2; // d=2 → dx=dy=2×0.5×cos45°
      final A = const Pt(0, 0);
      final B = const Pt(5, 0);
      final C = const Pt(5, 3);
      final D = const Pt(0, 3);
      final E = D + Pt(s2, s2);
      final F = C + Pt(s2, s2);
      final G = B + Pt(s2, s2);
      final H = A + Pt(s2, s2);
      final V = [A, B, C, D, E, F, G, H];

      int vid(Pt p) {
        for (var i = 0; i < V.length; i++) {
          if (V[i].distTo(p) < 1e-6) return i;
        }
        fail('线段端点 (${p.x},${p.y}) 不在 8 个顶点里 —— 图上混进了不属于长方体的线');
      }

      final lines = r.scene.shapes.whereType<SLine>().toList();
      expect(lines.length, 6, reason: '剪影 6 条走 polyline，独立棱应有 6 条');
      const solidEdges = [[1, 2], [2, 3], [2, 5]]; // 正面右竖棱/顶棱 + 顶面右缘
      const dashedEdges = [[4, 7], [7, 0], [7, 6]]; // 后左竖棱 + 底面两条隐藏棱
      var nDashed = 0;
      for (final l in lines) {
        final pair = <int>{vid(l.a), vid(l.b)};
        final isDashed = l.style == LineStyle.dashed;
        if (isDashed) nDashed++;
        final expected = isDashed ? dashedEdges : solidEdges;
        expect(
          expected.any((e) => pair.contains(e[0]) && pair.contains(e[1])),
          isTrue,
          reason: '有一条 ($l) 不是长方体的棱 —— 曾经把左/右面的对角线当棱画',
        );
      }
      expect(nDashed, 3, reason: '被挡住的棱恰 3 条');

      final poly = r.scene.shapes.whereType<SPolyline>().single;
      expect(poly.closed, isTrue);
      final silhouette = [A, B, G, F, E, D];
      for (var i = 0; i < silhouette.length; i++) {
        expect(poly.pts[i].distTo(silhouette[i]), closeTo(0, 1e-6));
      }
    });

    test('展开图配棱长标注（spec 带 edge 时），老 spec 重放不受影响', () {
      final labeled = FigureSolver.solve(FigureSpec(
        type: FigureType.cubeNet,
        params: {'edge': 4},
        text: {'layout': 'cross'},
      ));
      expect(
        labeled.scene.labels.any((l) => l.kind == LabelKind.length && l.text.contains('4')),
        isTrue,
      );
      final legacy = FigureSolver.solve(FigureSpec(
        type: FigureType.cubeNet,
        text: {'layout': 'cross'}, // 老错题的 spec 没有 edge 参数
      ));
      expect(legacy.scene.labels.where((l) => l.kind == LabelKind.length), isEmpty);
    });
  });

  group('比例与角度正确性', () {
    test('6cm 的边必须真的是 4cm 边的 1.5 倍', () {
      final a = FigureSolver.solve(FigureSpec(type: FigureType.rect, params: {'w': 4, 'h': 4}));
      final b = FigureSolver.solve(FigureSpec(type: FigureType.rect, params: {'w': 6, 'h': 4}));
      expect(b.scene.extent.w / a.scene.extent.w, closeTo(1.5, 1e-9));
    });

    test('一般三角形：底、高、垂足位置严格按 spec 落坐标', () {
      // 构建器的契约是「底 a + 高 h + 垂足 foot」—— 曾经的"三边定形"契约
      // 被刻意废除：先编三条边再画图，解出的高与题面不一致（见 planar.dart 注释）。
      final r = FigureSolver.solve(FigureSpec(
        type: FigureType.triangleGeneral,
        params: {'a': 5, 'h': 4, 'foot': 0.35},
      ));
      final poly = r.scene.shapes.whereType<SPolyline>().first;
      final A = poly.pts[0];
      final B = poly.pts[1];
      final C = poly.pts[2];
      expect(B.distTo(C), closeTo(5, 1e-9)); // 底 = a
      expect(A.x, closeTo(5 * 0.35, 1e-9)); // 垂足在 0.35 处
      expect(A.y, closeTo(4, 1e-9)); // 高严格等于 h
      // 高线：A 垂直落到 BC 上
      final hline = r.scene.shapes.whereType<SLine>().where((l) => l.style == LineStyle.dashed).single;
      expect(hline.a, A);
      expect(hline.b, Pt(A.x, 0));
      expect(hline.a.distTo(hline.b), closeTo(4, 1e-9));
      // 面积 = a×h/2 = 10
      expect(r.facts['area']!.display, '10 平方厘米');
    });

    test('直角三角形直角标记正确，面积 = ab/2', () {
      final r = FigureSolver.solve(FigureSpec(
        type: FigureType.triangleRight,
        params: {'a': 6, 'b': 4},
      ));
      expect(r.facts['area']!.display, '12 平方厘米');
      expect(r.scene.shapes.whereType<SRightAngle>().length, 1);
    });
  });

  group('退化与异常兜底', () {
    test('非法三角形必须报错而不是画出错图', () {
      // 底/高契约下，非法输入是非正数（旧契约的"三边不等式"已不存在）
      expect(
        () => FigureSolver.solve(FigureSpec(
          type: FigureType.triangleGeneral,
          params: {'a': 0, 'h': 4},
        )),
        throwsA(isA<FigureSolveError>()),
      );
      expect(
        () => FigureSolver.solve(FigureSpec(
          type: FigureType.triangleGeneral,
          params: {'a': 5, 'h': -1},
        )),
        throwsA(isA<FigureSolveError>()),
      );
    });

    test('圆环内半径大于外半径必须报错', () {
      expect(
        () => FigureSolver.solve(FigureSpec(
          type: FigureType.ring,
          params: {'r': 5, 'R': 3},
        )),
        throwsA(isA<FigureSolveError>()),
      );
    });

    test('扇形图数据为空必须报错', () {
      expect(
        () => FigureSolver.solve(FigureSpec(type: FigureType.pieChart)),
        throwsA(isA<FigureSolveError>()),
      );
    });
  });

  group('标注避让', () {
    test('相邻标注必须被推开到最小间距以上', () {
      final r = FigureSolver.solve(FigureSpec(type: FigureType.rect, params: {'w': 6, 'h': 4}));
      final ls = r.scene.labels;
      for (var i = 0; i < ls.length; i++) {
        for (var j = i + 1; j < ls.length; j++) {
          expect(ls[i].at.distTo(ls[j].at), greaterThanOrEqualTo(0.6),
              reason: '标注 ${ls[i].text} 与 ${ls[j].text} 重叠');
        }
      }
    });
  });

  group('DSL 不含坐标', () {
    test('FigureSpec 从 JSON 解析后仍只有语义参数', () {
      final spec = FigureSpec.fromJson({
        'type': 'triangleRight',
        'params': {'a': 6, 'b': 4},
        'unit': 'cm',
        'grade': 5,
      });
      expect(spec.type, FigureType.triangleRight);
      expect(spec.p('a', 0), 6);
      expect(spec.params.containsKey('x'), isFalse);
      expect(spec.params.containsKey('y'), isFalse);
    });
  });

  group('出题器抽样：立体图形', () {
    test('展开图判断题「能/不能」都要出现，不能让孩子无脑答"能"', () {
      final gen = QuizGenerator(seed: 20260718);
      final displays = <String>{};
      var judgments = 0;
      for (var i = 0; i < 400; i++) {
        final q = gen.generate(grade: 5, unit: '展开图');
        // 同一厂出的两类题：判断题 kind=cubeNet，表面积题 kind=cuboidSurface
        if (q.kind == 'cubeNet') {
          expect(q.stem.startsWith('下面这个展开图'), isTrue);
          judgments++;
          displays.add(q.answer.display);
        } else {
          expect(q.kind, 'cuboidSurface');
        }
      }
      expect(judgments, greaterThan(50));
      expect(displays, containsAll(['能', '不能']),
          reason: '判断题池子里全是可折布局时，答案永远是"能"——题目白出');
    });
  });
}
