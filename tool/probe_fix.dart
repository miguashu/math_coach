/// 临时探针：验证两个修复（kp 年级优先 + 长方体键名）。
/// 跑法：dart run tool/probe_fix.dart
import 'package:math_coach/geometry/dsl/figure.dart';
import 'package:math_coach/geometry/solver/solver.dart';
import 'package:math_coach/knowledge/kp_index.dart';
import 'package:math_coach/quiz/generator.dart';

void main() {
  // 1) 五年级问"长方形"，应落到三年级"长方形面积"，不再是一年级"认识图形·长方形"
  for (final g in [1, 3, 4, 5, 6]) {
    final r = KnowledgeIndex().match(knowledgePoint: '长方形', grade: g);
    print('G$g 长方形 → ${r.point?.path}  (${r.level.label})');
  }
  final r5 = KnowledgeIndex().match(knowledgePoint: '三角形的面积', grade: 6);
  print('G6 三角形的面积 → ${r5.point?.path}');
  final r6 = KnowledgeIndex().match(knowledgePoint: '体积', grade: 5);
  print('G5 体积 → ${r6.point?.path}');

  // 2) 长方体：题面 5×3×6，图上标注必须也是 5/3/6
  final spec = FigureSpec(
      type: FigureType.cuboidOblique,
      params: {'w': 5.0, 'h': 6.0, 'd': 3.0},
      unit: 'cm',
      grade: 5);
  final scene = FigureSolver.solve(spec).scene;
  for (final l in scene.labels) {
    print('label ${l.text}');
  }
  // 旧 spec（a/b/c）也要能正确还原
  final old = FigureSpec(
      type: FigureType.cuboidOblique,
      params: {'a': 5.0, 'b': 3.0, 'c': 6.0},
      unit: 'cm',
      grade: 5);
  for (final l in FigureSolver.solve(old).scene.labels) {
    print('old-spec label ${l.text}');
  }

  // 3) 知识点覆盖检查：五年级下拉里哪些单元本地题库没有模板
  final gen = QuizGenerator(seed: 7);
  for (final u in KnowledgeTree.unitsOf(KnowledgeIndex(), 5)) {
    if (!gen.covers(grade: 5, unit: u.name)) print('G5 未覆盖单元: ${u.name}');
  }
}
