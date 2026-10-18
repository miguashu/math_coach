/// 临时探针：真实联网跑一遍「错题 → 衍生题」，看两道闸门（本地模板 / 模型+本地复算）
/// 在真实模型面前的脾气。
///
/// 跑法：
///   dart run tool/derive_probe.dart                      # 默认：一道乘法题 + 一道长方体题
///   dart run tool/derive_probe.dart 5 cuboid             # 指定年级 + 题型
///
/// 注意：这里**只打印能进题库的题**（过了本地验算的），
/// 被丢弃的题目数在最后一行 —— 那才是这条链的关键指标。
import 'dart:io';

import 'package:math_coach/ai/config.dart';
import 'package:math_coach/ai/derive.dart';
import 'package:math_coach/ai/llm.dart';
import 'package:math_coach/quiz/question.dart';
import 'package:math_coach/store/bank.dart';

QuizQuestion _q(String id, String stem, String ans, String kind,
        {int grade = 3, double? value}) =>
    QuizQuestion(
      id: id,
      kpPath: '数与代数 / 数与运算',
      stem: stem,
      solutionSteps: const ['看题，列式，算'],
      answer: QuizAnswer(display: ans, value: value),
      kind: kind,
      grade: grade,
    );

Future<void> main(List<String> args) async {
  final grade = int.tryParse(args.isNotEmpty ? args[0] : '') ?? 5;
  final kind = args.length > 1 ? args[1] : '';

  // 两类错题混着来：一类本地有模板（不联网），一类只能问模型（长方体）
  final wrong = <QuizQuestion>[
    if (kind.isEmpty || kind == 'mul')
      _q('p1', '每盒有 24 支彩笔，买 7 盒，一共有多少支？', '168', 'mul', grade: 3, value: 168),
    if (kind.isEmpty || kind == 'cuboid')
      _q('p2', '一个长方体的长是 4 厘米，宽是 3 厘米，高是 2 厘米，它的体积是多少？',
          '24立方厘米', 'cuboid', grade: grade),
    if (kind == 'word')
      _q('p3', '甲、乙两车同时从两地相对开出，甲车每小时行 60 千米，乙车每小时行 45 千米，'
          '3 小时后相遇，两地相距多少千米？', '315千米', 'shopping', grade: grade),
  ];

  final sw = Stopwatch()..start();
  final out = await DeriveAgent(client: LlmClient(AiConfig.fallback)).deriveAll(wrong);
  sw.stop();

  print('错题 ${wrong.length} 道 → 入库候选 ${out.entries.length} 道'
      '（其中模型出 ${out.aiCount} 道）总耗时 ${sw.elapsedMilliseconds}ms');
  for (final e in out.entries) {
    print('\n── ${e.origin == 'ai' ? '[AI]' : '[本地]'} ${e.stem}');
    print('   答案：${e.answer}   来源错题：${e.sourceStem}');
    print('   提示：${e.steps.join(' / ')}');
    // 自己再验一遍：拿题库里的答案文本喂本地判分
    final ok = e.toQuestion().answer.check(e.answer);
    print('   本地判分自检：${ok ? "通过" : "不通过（这是 bug）"}');
  }
  if (out.skipped.isNotEmpty) {
    print('\n没能衍生的错题：');
    out.skipped.forEach((k, v) => print('  $k → $v'));
  }
  print('\n题库 id 去重检查：${out.entries.map((e) => e.id).toSet().length}'
      ' / ${out.entries.length}');
  if (out.entries.isNotEmpty) {
    print('示例 id：${QuestionBank.idFor(out.entries.first.stem)}');
  }
  if (out.entries.isEmpty) exit(1);
}
