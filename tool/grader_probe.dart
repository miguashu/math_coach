/// 临时探针：真实联网判一张手写答卷，看"认字→本地判分→批语"整条链。
///
/// 跑法：
///   python tool/make_grade_sample.py tool/testdata/grade_sample.jpg   # 先生成图
///   dart run tool/grader_probe.dart tool/testdata/grade_sample.jpg
///
/// 注：探针跑在纯 Dart VM 上（没有 dart:ui），图片不缩放直接传 JPEG 字节；
/// App 里那一层缩图在 grade_page._toBase64。样例图已由 Python 控制在合适尺寸。
import 'dart:convert';
import 'dart:io';

import 'package:math_coach/ai/config.dart';
import 'package:math_coach/ai/grader.dart';
import 'package:math_coach/ai/llm.dart';
import 'package:math_coach/quiz/question.dart';

Future<void> main(List<String> args) async {
  final path = args.isNotEmpty ? args[0] : 'tool/testdata/grade_sample.jpg';
  final f = File(path);
  if (!await f.exists()) {
    print('找不到图片：$path（先跑 python tool/make_grade_sample.py）');
    exit(1);
  }

  // 和合成图一致的题目（答案本地算，不来自模型）
  final paper = <QuizQuestion>[
    QuizQuestion(
      id: 'g1',
      kpPath: '加减法',
      stem: '书店买来 237 本故事书，上午卖出 158 本，还剩多少本？',
      solutionSteps: const ['总本数减去卖出的就是剩下的。', '237-158=79。'],
      answer: const QuizAnswer(display: '79', value: 79),
      kind: 'sub',
      grade: 3,
    ),
    QuizQuestion(
      id: 'g2',
      kpPath: '有余数的除法',
      stem: '47 个苹果平均装在 6 个篮子里，每篮几个？还剩几个？',
      solutionSteps: const ['47÷6=7……5。', '余数要比除数小。'],
      answer: const QuizAnswer(display: '7……5'),
      kind: 'div-r',
      grade: 3,
    ),
    QuizQuestion(
      id: 'g3',
      kpPath: '小数减法',
      stem: '一瓶饮料 0.5 升，倒出 0.25 升，还剩多少升？',
      solutionSteps: const ['0.5-0.25=0.25。', '小数点对齐再减。'],
      answer: const QuizAnswer(display: '0.25', value: 0.25),
      kind: 'dec',
      grade: 3,
    ),
    QuizQuestion(
      id: 'g4',
      kpPath: '乘法',
      stem: '直接写出得数：25 × 4 ＝ ？',
      solutionSteps: const ['25×4=100。', '先算 25×4。'],
      answer: const QuizAnswer(display: '100', value: 100),
      kind: 'mul',
      grade: 3,
    ),
    QuizQuestion(
      id: 'g5',
      kpPath: '乘法',
      stem: '停车场有 3 排轿车，每排 8 辆，一共有多少辆？',
      solutionSteps: const ['3×8=24。', '排数×每排辆数。'],
      answer: const QuizAnswer(display: '24', value: 24),
      kind: 'mul',
      grade: 3,
    ),
  ];

  // 直接传 JPEG 字节（VM 上没有 dart:ui 做缩图，见文件头说明）
  final bytes = await f.readAsBytes();
  final b64 = base64Encode(bytes);

  final agent = GradeAgent(LlmClient(AiConfig.fallback),
      fallbackModel: AiConfig.fallback.visionFallbackModel);
  final sw = Stopwatch()..start();
  final res = await agent.readAnswers(imageBase64: b64, questions: paper);
  sw.stop();

  print('认卷耗时 ${res.latencyMs}ms（总 ${sw.elapsedMilliseconds}ms）'
      ' tokens=${res.totalTokens} model=${res.model}');
  if (res.error != null) print('错误：${res.error}');
  if (!res.ok) exit(1);

  final byNo = {for (final it in res.items) it.no: it};
  final wrong = <({int no, QuizQuestion q, String read})>[];
  print('');
  for (var i = 0; i < paper.length; i++) {
    final q = paper[i];
    final read = byNo[i + 1];
    if (read == null || read.unclear) {
      print('第 ${i + 1} 题：未识别（${read?.note ?? "没读到"}）→ 不判错');
      continue;
    }
    final ok = q.answer.check(read.answer);
    print('第 ${i + 1} 题：认出 "${read.answer}" → 本地判${ok ? "对" : "错"}'
        '（正确答案 ${q.answer.display}）');
    if (!ok) wrong.add((no: i + 1, q: q, read: read.answer));
  }

  if (wrong.isNotEmpty) {
    print('\n── AI 批语 ──');
    final comments =
        await agent.writeComments(wrong: wrong, grade: 3);
    for (final w in wrong) {
      print('第 ${w.no} 题：${comments[w.no] ?? "（没写出来）"}');
    }
  }
}
