/// AI 判卷 Agent 回归用例（离线，注入 FakeLlm）。
///
/// 本机跑不了 `dart test`（Dart VM 无法以管道模式 spawn 子进程），
/// 断言写成可直接 `dart run` 的脚本。
///
/// 覆盖重点（这个 Agent 的生死线）：
/// - **模型只认字**：发给模型的 prompt 里不许出现正确答案；
/// - **对错本地判**：模型认 "396" 会被本地判分逮住判错；
///   全角/单位/小数尾零/余数写法都走本地规范化，不冤枉也不放水；
/// - **认不出不判错**：空答案或带 note 的一律 unclear，不进判分；
/// - 批语失败不影响判卷结果。
///
/// 跑法：dart run test/grader_manual.dart
import 'dart:io';

import 'package:math_coach/ai/grader.dart';
import 'package:math_coach/ai/llm.dart';
import 'package:math_coach/quiz/question.dart';

int _pass = 0;
int _fail = 0;

void ck(String name, bool ok, [String why = '']) {
  if (ok) {
    _pass++;
    print('PASS  $name');
  } else {
    _fail++;
    print('FAIL  $name ${why.isEmpty ? '' : '→ $why'}');
  }
}

class FakeLlm implements LlmPort {
  final List<LlmReply> queue;
  final List<String> seenUser = [];
  final List<bool> seenVision = [];
  final List<String?> seenModelOverride = [];
  FakeLlm(this.queue);

  @override
  Future<LlmReply> chat(
    List<LlmMessage> messages, {
    bool vision = false,
    double temperature = 0.3,
    int maxTokens = 1600,
    Duration timeout = const Duration(seconds: 90),
    String? modelOverride,
  }) async {
    for (final m in messages.reversed) {
      if (m.role == 'user') {
        seenUser.add(m.text);
        break;
      }
    }
    seenVision.add(vision);
    seenModelOverride.add(modelOverride);
    if (queue.isEmpty) throw const LlmError('队列空了（不该发生）');
    return queue.removeAt(0);
  }
}

LlmReply _r(String text) =>
    LlmReply(text: text, totalTokens: 100, latencyMs: 50, model: 'fake');

QuizQuestion _q(
  String id,
  String stem,
  String answer, {
  double? value,
  List<String> steps = const ['先看已知条件。', '再列式计算。'],
}) =>
    QuizQuestion(
      id: id,
      kpPath: '测试',
      stem: stem,
      solutionSteps: steps,
      answer: QuizAnswer(display: answer, value: value),
      kind: 'test',
      grade: 3,
    );

const _readOk = '''
{"items":[
 {"no":1,"answer":"79","note":""},
 {"no":2,"answer":"7……5","note":""},
 {"no":3,"answer":"0.50","note":""},
 {"no":4,"answer":"","note":"未作答"}
]}''';

void main() async {
  final paper = <QuizQuestion>[
    _q('q1', '书店买来 237 本故事书，上午卖出 158 本，还剩多少本？', '79', value: 79),
    _q('q2', '47 个苹果平均装在 6 个篮子里，每篮几个？还剩几个？', '7……5'),
    _q('q3', '一瓶饮料 0.5 升，倒出 0.25 升，还剩多少升？', '0.5', value: 0.5),
    _q('q4', '直接写出得数：25×4＝？', '100', value: 100),
  ];

  // 1) 认字 + 本地判分全链路
  {
    final llm = FakeLlm([_r(_readOk)]);
    final agent = GradeAgent(llm);
    final res = await agent.readAnswers(imageBase64: 'x', questions: paper);
    ck('认出 4 条', res.items.length == 4, '实得 ${res.items.length}');
    ck('无错误信息', res.error == null, res.error ?? '');

    // 铁律：认字阶段的 prompt 不许泄露正确答案
    final prompt = llm.seenUser.join('\n');
    ck('prompt 不含正确答案 79', !prompt.contains('79'), prompt);
    ck('prompt 不含正确答案 100', !prompt.contains('100'), prompt);
    ck('prompt 含题号引导', prompt.contains('第 1 题'));

    final byNo = {for (final it in res.items) it.no: it};
    final v1 = byNo[1]!;
    ck('第1题认出 79', v1.answer == '79');
    ck('第1题清晰可判', !v1.unclear);
    final q1 = paper[0];
    ck('第1题本地判对', q1.answer.check(v1.answer));

    final v2 = byNo[2]!;
    ck('第2题余数写法原样保留', v2.answer == '7……5');
    ck('第2题本地判对（余数没被抹掉）', paper[1].answer.check(v2.answer));

    final v3 = byNo[3]!;
    ck('第3题小数尾零本地判对', paper[2].answer.check(v3.answer));

    final v4 = byNo[4]!;
    ck('第4题未作答 → unclear', v4.unclear);
  }

  // 2) 模型认错字：本地判分必须逮住（不能模型说对就对）
  {
    final llm = FakeLlm([
      _r('{"items":[{"no":1,"answer":"96","note":""}]}')
    ]);
    final res = await GradeAgent(llm).readAnswers(imageBase64: 'x', questions: paper);
    final it = res.items.first;
    ck('认成 96 不改写', it.answer == '96');
    ck('96 本地判错', !paper[0].answer.check(it.answer));
  }

  // 3) 手写宽容度：全角 / 带单位 / 只写商漏余数
  {
    final llm = FakeLlm([
      _r('{"items":[{"no":1,"answer":"７９ 元","note":""},'
          '{"no":2,"answer":"7","note":""}]}')
    ]);
    final res = await GradeAgent(llm).readAnswers(imageBase64: 'x', questions: paper);
    ck('全角+单位本地判对', paper[0].answer.check(res.items[0].answer));
    ck('漏写余数本地判错（这是考点）', !paper[1].answer.check(res.items[1].answer));
  }

  // 4) 字迹不清：note 非空 → unclear，不判分
  {
    final llm = FakeLlm([
      _r('{"items":[{"no":1,"answer":"39?","note":"第1题字迹潦草"}]}')
    ]);
    final res = await GradeAgent(llm).readAnswers(imageBase64: 'x', questions: paper);
    ck('字迹不清标 unclear', res.items.first.unclear);
  }

  // 5) 模型不守 JSON → 按没认出处理，不猜
  {
    final llm = FakeLlm([_r('照片太糊了我看不清')]);
    final res = await GradeAgent(llm).readAnswers(imageBase64: 'x', questions: paper);
    ck('非 JSON 返回空并报错', res.items.isEmpty && res.error != null, res.error ?? '');
  }

  // 6) 空题目列表
  {
    final llm = FakeLlm([_r('{}')]);
    final res = await GradeAgent(llm).readAnswers(imageBase64: 'x', questions: const []);
    ck('空题本直接报错', res.items.isEmpty && res.error != null);
  }

  // 7) 批语：按题号返回，prompt 不带答案泄露风险（只给孩子写的和正确思路）
  {
    final llm = FakeLlm([
      _r('{"items":[{"no":2,"comment":"余数要比除数小，再检查一下最后一步。"}]}')
    ]);
    final comments = await GradeAgent(llm).writeComments(
      wrong: [
        (no: 2, q: paper[1], read: '9……3'),
      ],
      grade: 3,
    );
    ck('批语按题号返回', comments[2] != null && comments[2]!.isNotEmpty);
    ck('批语不提正确答案', !comments[2]!.contains('7……5'));
    ck('批语调用是文字通道', llm.seenVision.isNotEmpty);
  }

  // 8) 批语失败（网络错）不抛异常，返回空
  {
    final llm = FakeLlm(<LlmReply>[]); // 空队列 → 抛 LlmError
    final comments = await GradeAgent(llm).writeComments(
      wrong: [(no: 1, q: paper[0], read: '396')],
    );
    ck('批语失败返回空 map 不崩', comments.isEmpty);
  }

  // 9) 主模型不存在 → 自动降级备胎
  {
    final llm = FakeLlm(<LlmReply>[]);
    // 第一次调用抛 modelMissing，第二次（备胎）成功
    llm.queue.add(_r('{"items":[{"no":1,"answer":"395","note":""}]}'));
    // 手动让第一次抛错：用一个会抛的 FakeLlm 变体
    final throwing = _ThrowingOnce(llm);
    final res = await GradeAgent(throwing, fallbackModel: 'qwen3-vl-plus')
        .readAnswers(imageBase64: 'x', questions: paper);
    ck('降级备胎后认出答案', res.items.length == 1 && res.error == null, res.error ?? '');
    ck('降级时用了备胎模型名', throwing.seenModelOverride.contains('qwen3-vl-plus'));
  }

  print('\n$_pass 通过 / $_fail 失败');
  if (_fail > 0) exit(1);
}

/// 第一次调用抛「模型不存在」，之后正常吐队列。
class _ThrowingOnce implements LlmPort {
  final FakeLlm inner;
  bool thrown = false;
  _ThrowingOnce(this.inner);
  List<String?> get seenModelOverride => inner.seenModelOverride;

  @override
  Future<LlmReply> chat(
    List<LlmMessage> messages, {
    bool vision = false,
    double temperature = 0.3,
    int maxTokens = 1600,
    Duration timeout = const Duration(seconds: 90),
    String? modelOverride,
  }) async {
    if (!thrown) {
      thrown = true;
      throw const LlmError('模型不存在', modelMissing: true);
    }
    return inner.chat(messages,
        vision: vision,
        temperature: temperature,
        maxTokens: maxTokens,
        timeout: timeout,
        modelOverride: modelOverride);
  }
}
