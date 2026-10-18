/// 临时探针：真实联网调模型出题，看闸门行为与题目质量。
/// 跑法：dart run tool/quizgen_probe.dart [年级] [难度档1-3] [知识点]
import 'dart:io';

import 'package:math_coach/ai/config.dart';
import 'package:math_coach/ai/llm.dart';
import 'package:math_coach/ai/quizgen.dart';

Future<void> main(List<String> args) async {
  final grade = int.tryParse(args.isNotEmpty ? args[0] : '5') ?? 5;
  final level = QuizLevel.fromValue(int.tryParse(args.isNotEmpty ? args[1] : '3') ?? 3);
  final unit = args.length > 2 ? args[2] : null;

  final sw = Stopwatch()..start();
  final res = await QuizAgent(LlmClient(AiConfig.fallback)).generate(
    grade: grade,
    unit: unit,
    count: 4,
    level: level,
  );
  sw.stop();

  print('档位=${level.label} 年级=$grade 知识点=${unit ?? "不限"} '
      'attempts=${res.attempts} 丢弃=${res.discarded} 耗时=${res.latencyMs}ms '
      '总耗时=${sw.elapsedMilliseconds}ms');
  if (res.error != null) print('错误：${res.error}');
  for (var i = 0; i < res.questions.length; i++) {
    final q = res.questions[i];
    print('\n── 第 ${i + 1} 题（难度 ${q.difficulty}）${q.kp}');
    print('   ${q.stem}');
    print('   答案：${q.answer}${q.unit.isNotEmpty ? " ${q.unit}" : ""}'
        '   验算：${q.equation}');
    for (final s in q.steps) {
      print('     · $s');
    }
  }
  if (res.questions.isEmpty) exit(1);
}
