/// 衍生题库 + 衍生题 Agent 回归用例（离线，注入 FakeLlm）。
///
/// 本机跑不了 `dart test`（Dart VM 无法以管道模式 spawn 子进程），
/// 断言写成可直接 `dart run` 的脚本。
///
/// 覆盖重点（这条链的生死线）：
/// - **题库去重靠规范化题干**：同一道题反复生成不许在题库里堆成三份；
/// - **入库的答案必须过本地验算**：模型给不出验算式 / 算式与答案对不上 /
///   题干要配图 → 整道丢弃（题库是持久的，一道错答案会被练很多遍）；
/// - **本地优先**：有模板的题型根本不联网；
/// - **出不来就说清楚**：不假装成功，把原因写进 skipped。
///
/// 跑法：dart run test/bank_manual.dart
import 'dart:io';

import 'package:math_coach/ai/derive.dart';
import 'package:math_coach/ai/llm.dart';
import 'package:math_coach/ai/variants.dart';
import 'package:math_coach/quiz/question.dart';
import 'package:math_coach/store/bank.dart';

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
  final List<String> seenSystem = [];
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
    for (final m in messages) {
      if (m.role == 'system') seenSystem.add(m.text);
    }
    for (final m in messages.reversed) {
      if (m.role == 'user') {
        seenUser.add(m.text);
        break;
      }
    }
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
  String kind = 'mul',
  int grade = 3,
  double? value,
}) =>
    QuizQuestion(
      id: id,
      kpPath: '数与代数 / 数的运算 / 乘法',
      stem: stem,
      solutionSteps: const ['看题，列式，算'],
      answer: QuizAnswer(display: answer, value: value),
      kind: kind,
      grade: grade,
    );

Future<void> main() async {
  // ── 1) id 稳定 + 规范化去重 ────────────────────────────
  {
    ck('同题干两次拿到同一个 id',
        QuestionBank.idFor('12 × 4 = ？') == QuestionBank.idFor('12 × 4 = ？'));
    ck('空白与全角不影响 id',
        QuestionBank.idFor('12 × 4 = ？') == QuestionBank.idFor('１２×４＝？'),
        '${QuestionBank.idFor('12 × 4 = ？')} vs ${QuestionBank.idFor('１２×４＝？')}');
    ck('不同题干 id 不同',
        QuestionBank.idFor('12 × 4 = ？') != QuestionBank.idFor('13 × 4 = ？'));
  }

  // ── 2) BankEntry 存读一致 ──────────────────────────────
  {
    final e = BankEntry(
      id: 'dv-1',
      sourceQuestionId: 'q7',
      sourceStem: '每盒有 12 支彩笔，买 4 盒，一共有多少支？',
      stem: '每盒有 21 支彩笔，买 6 盒，一共有多少支？',
      answer: '126支',
      answerValue: 126,
      unit: '支',
      steps: const ['先算一盒多少支'],
      kpPath: '数与代数 / 数的运算 / 乘法',
      kpCode: 'MA-G3-S1-NA-04-02',
      grade: 3,
      difficulty: 2,
      origin: 'local',
      createdAt: DateTime.fromMillisecondsSinceEpoch(1700000000000),
      attempts: 2,
      wrongCount: 1,
      streak: 1,
      passed: false,
    );
    final back = BankEntry.fromMap(e.toMap());
    ck('存读：答案与单位',
        back.answer == '126支' && back.unit == '支' && back.answerValue == 126);
    ck('存读：来源错题', back.sourceQuestionId == 'q7' && back.sourceStem.contains('12 支'));
    ck('存读：练习痕迹',
        back.attempts == 2 && back.wrongCount == 1 && back.streak == 1 && !back.passed);
    ck('存读：时间戳', back.createdAt.millisecondsSinceEpoch == 1700000000000);
  }

  // ── 3) 入账去重 + 过关逻辑 + 落盘 ──────────────────────
  {
    final dir = await Directory.systemTemp.createTemp('bank_test');
    final f = File('${dir.path}${Platform.pathSeparator}bank.json');
    final bank = QuestionBank(file: f);

    final e1 = _entry('q1', '每盒有 21 支彩笔，买 6 盒，一共有多少支？', '126支');
    ck('首次入账 = 1 条', await bank.addAll([e1]) == 1);
    ck('同题再入账被挡掉', await bank.addAll([e1]) == 0);
    ck('题干只差空格也挡掉',
        await bank.addAll([_entry('q1', '每盒有 21 支彩笔，买 6 盒，一共有多少支？ ', '126支')]) == 0);
    ck('换一道题能进', await bank.addAll([_entry('q1', '每盒有 23 支彩笔，买 5 盒，一共有多少支？', '115支')]) == 1);
    ck('题库共 2 条', bank.count == 2, '${bank.count}');

    // 答对一次不算过关（换数字的题，一次可能是顺出来的）
    await bank.record(e1.id, correct: true);
    var got = bank.get(e1.id)!;
    ck('答对一次：streak 1、未过关',
        got.streak == 1 && !got.passed && got.attempts == 1, 'streak=${got.streak}');
    // 连对两次过关
    await bank.record(e1.id, correct: true);
    got = bank.get(e1.id)!;
    ck('连对两次：过关', got.passed && got.streak == 2, 'streak=${got.streak}');
    // 过关后答错：记录如实，但勋章不收回
    await bank.record(e1.id, correct: false);
    got = bank.get(e1.id)!;
    ck('答错：streak 归零、错题数 +1', got.streak == 0 && got.wrongCount == 1);
    ck('已过关不被一次手滑收回', got.passed);
    ck('未过关数 = 1', bank.pendingCount == 1, '${bank.pendingCount}');

    // 落盘 → 重新读
    final bank2 = QuestionBank(file: f);
    await bank2.load();
    ck('重开后条数一致', bank2.count == 2, '${bank2.count}');
    ck('重开后痕迹保留', bank2.get(e1.id)!.attempts == 3 && bank2.get(e1.id)!.passed);

    // 分组与统计
    ck('覆盖 1 道错题', bank2.sourceCount == 1, '${bank2.sourceCount}');
    final g = bank2.groups;
    ck('一组两道题', g.length == 1 && g.first.entries.length == 2);
    ck('组里有未过关的', g.first.pending >= 1);
    ck('未过关的排在前面', bank2.all.first.passed == false);

    // 删来源题连带清衍生题
    ck('按来源删除', await bank2.removeBySource('q1') == 2 && bank2.count == 0);

    // 数据文件损坏不能让 App 崩
    await f.writeAsString('{ 这不是 json');
    final bank3 = QuestionBank(file: f);
    await bank3.load();
    ck('坏文件：空库继续', bank3.count == 0);
    final broken = dir
        .listSync()
        .where((e) => e.path.contains('.broken-'))
        .toList();
    ck('坏文件被改名备份', broken.isNotEmpty, '${broken.length}');
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  }

  // ── 4) 衍生：有模板的题型走本地，完全不联网 ─────────────
  {
    final src = _q('q1', '每盒有 24 支彩笔，买 7 盒，一共有多少支？', '168', value: 168);
    final llm = FakeLlm(const []); // 队列空 = 一旦发请求就抛错，用来证明"没联网"
    final out = await DeriveAgent(client: llm, seed: 7).deriveAll([src]);
    ck('本地出了 3 道', out.entries.length == 3, '${out.entries.length}');
    ck('全部标 local', out.entries.every((e) => e.origin == 'local'));
    ck('一道都没问模型', out.aiCount == 0 && llm.seenUser.isEmpty);
    ck('题干与错题不同',
        out.entries.every((e) => e.stem != src.stem),
        out.entries.first.stem);
    ck('答案非空且自带判分依据',
        out.entries.every((e) => e.answer.isNotEmpty && e.answerValue != null));
    ck('可判分：答案文本能判对',
        out.entries.every((e) => e.toQuestion().answer.check(e.answer)));
    ck('挂在同一道错题下',
        out.entries.every((e) => e.sourceQuestionId == 'q1' && e.sourceStem == src.stem));
    ck('知识点沿用错题的', out.entries.every((e) => e.kpPath == src.kpPath));
  }

  // ── 5) 衍生：余数题的答案写法不许被抹掉 ─────────────────
  {
    final src = _q('q2', '把 47 个苹果平均分给 6 个小朋友，每人分几个，还剩几个？',
        '7……5', kind: 'divRem', grade: 2);
    final out = await DeriveAgent(client: null, seed: 3).deriveAll([src]);
    ck('余数题本地也能衍生', out.entries.length == 3, '${out.entries.length}');
    ck('衍生答案带余数', out.entries.every((e) => e.answer.contains('…')),
        out.entries.first.answer);
    ck('只写商会被判错（考点还在）',
        out.entries.every((e) => !e.toQuestion().answer.check(e.answer.split('…').first)),
        out.entries.first.answer);
  }

  // ── 6) 衍生：本地没模板且没配 key → 说清楚，不假装 ───────
  {
    final src = _q('q3', '一个长方体的长是 4 厘米，宽是 3 厘米，高是 2 厘米，体积是多少？',
        '24立方厘米', kind: 'cuboid', grade: 5);
    final out = await DeriveAgent(client: null).deriveAll([src]);
    ck('没模板没 key：0 道', out.entries.isEmpty && !out.ok);
    ck('skipped 里有原因', out.skipped['q3']?.contains('设置') == true, '${out.skipped}');
  }

  // ── 7) 衍生：模型出的题过本地验算才收 ───────────────────
  {
    final src = _q('q3', '一个长方体的长是 4 厘米，宽是 3 厘米，高是 2 厘米，体积是多少？',
        '24立方厘米', kind: 'cuboid', grade: 5);
    final llm = FakeLlm([
      _r('''{"items":[
        {"for":1,"stem":"一个长方体的长是 6 厘米，宽是 2 厘米，高是 3 厘米，体积是多少？",
         "answer":"36","unit":"立方厘米","equation":"6*2*3","hint":"体积＝长×宽×高"},
        {"for":1,"stem":"一个长方体的长是 5 厘米，宽是 2 厘米，高是 4 厘米，体积是多少？",
         "answer":"99","unit":"立方厘米","equation":"5*2*4","hint":"体积＝长×宽×高"},
        {"for":1,"stem":"一个长方体的长是 7 厘米，宽是 2 厘米，高是 2 厘米，体积是多少？",
         "answer":"28","unit":"立方厘米","equation":"","hint":""},
        {"for":1,"stem":"如下图，一个长方体的长是 3 厘米，宽是 3 厘米，高是 3 厘米，体积是多少？",
         "answer":"27","unit":"立方厘米","equation":"3*3*3","hint":""}
      ]}''')
    ]);
    final out = await DeriveAgent(client: llm, seed: 1).deriveAll([src]);
    ck('只收过验算的那一道', out.entries.length == 1, '${out.entries.length}');
    ck('收的是 36 那道', out.entries.single.answer == '36立方厘米', out.entries.single.answer);
    ck('标 ai 来源', out.aiCount == 1 && out.entries.single.isAi);
    ck('提示被收进讲解', out.entries.single.steps.first.contains('体积'));
    ck('答案错的那道被丢（99≠40）',
        out.entries.every((e) => !e.stem.contains('5 厘米，宽是 2 厘米，高是 4')));
    ck('没验算式的那道被丢', out.entries.every((e) => !e.stem.contains('7 厘米')));
    ck('要配图的那道被丢', out.entries.every((e) => !e.stem.contains('如下图')));
    ck('prompt 里带了原题干', llm.seenUser.first.contains('长是 4 厘米'));
    ck('prompt 要求每题给验算式', llm.seenSystem.first.contains('算式'));
  }

  // ── 8) 衍生：一次批改里多道错题混着来 ───────────────────
  {
    final a = _q('qa', '每盒有 24 支彩笔，买 7 盒，一共有多少支？', '168', value: 168);
    final b = _q('qb', '一个长方体的长是 4 厘米，宽是 3 厘米，高是 2 厘米，体积是多少？',
        '24立方厘米', kind: 'cuboid', grade: 5);
    final llm = FakeLlm([
      _r('{"items":[{"for":1,"stem":"一个长方体的长是 6 厘米，宽是 3 厘米，高是 2 厘米，体积是多少？",'
          '"answer":"36","unit":"立方厘米","equation":"6*3*2","hint":""}]}')
    ]);
    final out = await DeriveAgent(client: llm, seed: 5).deriveAll([a, b]);
    ck('本地的 3 道 + 模型的 1 道',
        out.entries.length == 4 && out.aiCount == 1, '${out.entries.length}');
    ck('模型的题挂在对的错题下',
        out.entries.where((e) => e.isAi).every((e) => e.sourceQuestionId == 'qb'));
    ck('只问了模型一次', llm.seenUser.length == 1, '${llm.seenUser.length}');
    // 有本地模板的题根本不进 prompt —— 省 token 也省时间
    ck('prompt 只列没模板的那道（长方体）', llm.seenUser.first.contains('长方体'));
    ck('有模板的题没进 prompt', !llm.seenUser.first.contains('彩笔'));
    ck('本地题挂在自己的错题下',
        out.entries.where((e) => !e.isAi).every((e) => e.sourceQuestionId == 'qa'));
  }

  // ── 9) 衍生：模型整批失败不崩，落到 skipped ─────────────
  {
    final src = _q('q3', '一个长方体的长是 4 厘米，宽是 3 厘米，高是 2 厘米，体积是多少？',
        '24立方厘米', kind: 'cuboid', grade: 5);
    final out = await DeriveAgent(client: FakeLlm(const [])).deriveAll([src]);
    ck('模型抛错：0 道且不崩', out.entries.isEmpty);
    ck('抛错也留下原因', (out.skipped['q3'] ?? '').contains('失败'), '${out.skipped}');
  }

  // ── 10) 解析器：模型爱用代码块包裹 ──────────────────────
  {
    final list = VariantAgent.parseReply('```json\n{"items":[{"for":2,"stem":"a","answer":"1",'
        '"unit":"","equation":"1","hint":"h"}]}\n```');
    ck('代码块里的 JSON 能抠出来', list.length == 1 && list.first.forIndex == 2);
    ck('hint 被解析', list.first.hint == 'h');
    ck('非 JSON 回复返回空表', VariantAgent.parseReply('我不知道').isEmpty);
  }

  // ── 11) 衍生：这些题型刻意不本地映射（名字相关 ≠ 算法相同）──
  {
    // 混合运算考的是运算顺序、植树考的是段数与点数、平均数一条式子既有乘也有除、
    // 梯形公式带 ÷2、立体图形是一维与三维的换算 —— 本地模板都练不到这些。
    for (final k in const [
      'mixOps',
      'interval',
      'average',
      'trapezoid',
      'cylinder',
      'cuboidSurface',
      'cubeNet',
      'derived',
    ]) {
      final llm = FakeLlm(const []); // 一发请求就抛错，正好用来证明"走了模型那条路"
      final src = _q('qm', '先想清楚运算顺序，再算：55 − 6 × 5 =', '25', kind: k, grade: 4);
      final out = await DeriveAgent(client: llm).deriveAll([src]);
      ck('$k 不走本地模板（问了模型）', llm.seenUser.length == 1,
          '问了 ${llm.seenUser.length} 次');
      ck('$k 出不来就如实记原因', out.entries.isEmpty && out.skipped.containsKey('qm'),
          '${out.skipped}');
    }
  }

  print('\n$_pass 通过 / $_fail 失败');
  exitCode = _fail == 0 ? 0 : 1;
}

BankEntry _entry(String srcId, String stem, String answer) => BankEntry(
      id: QuestionBank.idFor(stem),
      sourceQuestionId: srcId,
      sourceStem: '原题',
      stem: stem,
      answer: answer,
      answerValue: 0,
      kpPath: '数与代数 / 数的运算 / 乘法',
      grade: 3,
      origin: 'local',
      createdAt: DateTime.now(),
    );
