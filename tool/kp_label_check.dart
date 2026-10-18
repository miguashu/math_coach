/// 知识点标签体检：各年级卷子上**不许出现别的年级的前缀**。
///
/// 为什么单独一个检查：`KnowledgeIndex.match` 在当前年级找不到同名考点时会
/// 退到"最近年级"（A12 留下的保底），于是三年级卷子上会冒出
/// 「五上 · 数学广角 · 植树问题」这种标签。功能没错，但家长看到的是"年级串了"。
/// 修法在 `lib/quiz/generator.dart` 的 `Util.kpPath`（跨年级只印考点名）。
///
/// 跑法：dart run tool/kp_label_check.dart
import 'dart:io';

import 'package:math_coach/quiz/generator.dart';

const _cn = {1: '一', 2: '二', 3: '三', 4: '四', 5: '五', 6: '六'};

void main() {
  final g = QuizGenerator();
  final bad = <String>[];
  var total = 0;
  final perGrade = <int, Set<String>>{};

  for (final grade in [1, 2, 3, 4, 5, 6]) {
    final seen = <String>{};
    for (var round = 0; round < 6; round++) {
      for (final q in g.generateMany(count: 12, grade: grade)) {
        total++;
        final m = RegExp('([一二三四五六])[上下]').firstMatch(q.kpPath);
        if (m != null && m.group(1) != _cn[grade]) {
          bad.add('$grade 年级卷出现「${q.kpPath}」');
        }
        seen.add(q.kpPath);
      }
    }
    perGrade[grade] = seen;
  }

  for (final e in perGrade.entries) {
    print('${e.key} 年级：${e.value.length} 种知识点标签');
  }
  print('\n共查 $total 道题的标签');
  if (bad.isEmpty) {
    print('✅ 没有跨年级前缀');
  } else {
    for (final b in bad.take(10)) {
      print('❌ $b');
    }
    print('共 ${bad.length} 处');
    exitCode = 1;
  }
}
