/// AI 出题 Agent：难题、应用题、奥数题由模型出，答案全部本地复算。
///
/// 为什么要有它（用户原话）：
///   "生成的题能不能采用大模型生成几道困难的……生成对应的应用题，奥数水平"
///   "生成问题重复没有新意，都是固定几套。能不能大模型出新，系统补全"
/// 本地题库（quiz/generator.dart）是模板式的，一套参数翻来覆去就那几种形态，
/// 而且只覆盖了教材一部分单元（五年级 11 个单元里 6 个没有模板）。
/// 模型负责"出新"，本地负责"补全与把关"：
///
///   模型出题  →  本地验算（答案从 equation 用 Rational 精确重算）
///             →  本地补全（知识点归类、判分配置、难度、id 去重）
///             →  不合格整道丢弃，打回重做一次
///
/// 三条硬闸门（和 solver.dart 同一套哲学）：
///   1) **答案本地算**：展示答案是本地复算结果，不是模型报的数字；
///      模型报的答案和本地算的对不上 → 整道丢弃（它连自己都不认同）。
///   2) 没有可验算的 equation → 丢弃。不出验算不了的题，
///      否则就是"没验算却亮绿勾"。
///   3) 步骤少于 2 步 → 丢弃；题干含"如图/下表" → 丢弃
///      （本地画不出模型心里那张图，出了也是废题）。
library;

import 'dart:convert';
import 'dart:math' as math;

import '../core/rational.dart';
import '../knowledge/kp_index.dart';
import '../quiz/question.dart';
import 'expr.dart';
import 'llm.dart';

/// 难度档。基础档刻意不调模型 —— 离线也要能出题，且基础题本地模板更稳。
enum QuizLevel {
  basic(1, '基础', '课本同步：紧扣课本例题变形，数字工整，一步到两步就能做完'),
  boost(2, '提高', '课本综合：两到三步的应用题，条件和问题都要孩子自己理顺'),
  olympiad(3, '奥数挑战', '浅奥/竞赛：需要倒推、假设、列举或找规律，情境可以非常规');

  const QuizLevel(this.value, this.label, this.brief);
  final int value;
  final String label;

  /// 给模型看的难度描述（写进 prompt）。
  final String brief;

  static QuizLevel fromValue(int v) =>
      QuizLevel.values.firstWhere((l) => l.value == v, orElse: () => QuizLevel.basic);
}

/// 一道过了闸门的 AI 题（答案已是本地复算值）。
class GenQuestion {
  final String stem;

  /// 展示答案 = 本地复算结果（铁律：答案本地算）
  final String answer;

  /// 本地算出的数值（判分用），单位已剥离
  final double value;

  final String unit;
  final List<String> steps;

  /// 难度 1..5（模型自评，本地夹紧）
  final int difficulty;

  /// 模型自称的知识点，交由本地 KnowledgeIndex 再归类
  final String kp;

  /// 验算式（本地复算的依据，保留用于排查）
  final String equation;

  const GenQuestion({
    required this.stem,
    required this.answer,
    required this.value,
    required this.unit,
    required this.steps,
    required this.difficulty,
    required this.kp,
    required this.equation,
  });
}

class QuizGenResult {
  final List<GenQuestion> questions;

  /// 失败原因（网络/配置/模型不守格式）；questions 非空时仍算成功
  final String? error;

  /// 实际发起的调用次数（1 或 2）
  final int attempts;

  /// 两次调用合计耗时
  final int latencyMs;

  /// 模型自评难度与实际档位是否明显不符（信息性提示，不拦截）
  final int discarded;

  const QuizGenResult({
    required this.questions,
    this.error,
    this.attempts = 1,
    this.latencyMs = 0,
    this.discarded = 0,
  });

  bool get ok => questions.isNotEmpty;
}

class QuizAgent {
  final LlmPort client;
  QuizAgent(this.client);

  static const _system = '''
你是一位小学数学教研专家，同时精通小学奥数。请按给定年级和难度档出练习题。

硬性要求：
1. 每题都是完整应用题：有情境、有条件、有问题。情境要贴近孩子生活
   （购物分糖果、植树、行程、分组做实验、比赛计分……），同一批题里情境不重样。
2. 难度严格按用户给定的难度档执行，数字大小适合该年级，不超纲。
3. 答案只允许整数或有限小数；不出现负数、循环小数。
4. 每题必须给出：
   - stem：题干。一句话说清，**不要出现"如图""下图""看图""统计表"这类
     必须看配图才能做的表述**（出题系统画不出图）。
   - answer：最终答案，只写数字，单位另写在 unit 里。
   - unit：单位，如 个/厘米/平方厘米/元，没有就空字符串。
   - equation：从题目条件到最终答案的一条完整四则算式，只含数字和
     + - * / ( )，不写等号和答案（写 "20-5"，不要写 "20-5=15"）。
     写不成一条算式 = 这道题不合格。
   - steps：2~4 步分步讲解，每步像老师对孩子说话，最后一步落到答案和单位。
   - kp：本题考察的知识点，如 "小数乘法·解决问题"。
   - difficulty：1~5 的难度自评。
5. 题目之间不重复，也不要和用户列出的"已出过的题"重复。
6. 只输出 JSON，格式：
{"items":[{"stem":"","answer":"","unit":"","equation":"","steps":["",""],"kp":"","difficulty":3}]}''';

  /// 出 [count] 道题。任何一步失败都不抛异常，错误写进 [QuizGenResult.error]。
  ///
  /// [avoid] 是最近出过的题干（系统负责去重与避重，见 state.dart）。
  ///
  /// **为什么要分批**：实测一次要 4 道奥数题，deepseek-v4-flash 想了 30 秒、
  /// 烧掉大半个 token 预算；一次要 6~10 道只会更慢，还可能 finish=length
  /// 把正文挤没。所以按每次 ≤3 道拆分，一批失败只损失一批，
  /// 也不会把一次调用逼到超时。
  Future<QuizGenResult> generate({
    required int grade,
    String? unit,
    int count = 3,
    QuizLevel level = QuizLevel.boost,
    List<String> avoid = const [],
  }) async {
    // 单次出题量上限：一卷里 AI 题最多 6 道。再多的边际收益是"更新鲜"，
    // 边际成本是几十秒等待和更高的失败率 —— 本地题库补足更划算。
    final want = math.min(count, 6);
    final chunks = <int>[];
    for (var left = want; left > 0; left -= _chunk) {
      chunks.add(math.min(_chunk, left));
    }

    final all = <GenQuestion>[];
    var attempts = 0;
    var latency = 0;
    var discarded = 0;
    String? err;
    for (final n in chunks) {
      final r = await _generateChunk(
        grade: grade,
        unit: unit,
        count: n,
        level: level,
        // 已生成的题干也要避重：分批之间不能互相抄
        avoid: [...avoid, ...all.map((q) => q.stem)],
      );
      attempts += r.attempts;
      latency += r.latencyMs;
      discarded += r.discarded;
      all.addAll(r.questions);
      err ??= r.error;
    }
    return QuizGenResult(
      questions: all,
      error: all.isEmpty ? (err ?? '模型没有给出合格题目') : null,
      attempts: attempts,
      latencyMs: latency,
      discarded: discarded,
    );
  }

  static const _chunk = 3;

  /// 一批（≤3 道）：一次调用，不够就打回重做一次。
  Future<QuizGenResult> _generateChunk({
    required int grade,
    String? unit,
    required int count,
    required QuizLevel level,
    required List<String> avoid,
  }) async {
    final messages = <LlmMessage>[
      const LlmMessage('system', _system),
      LlmMessage('user',
          _userPrompt(grade: grade, unit: unit, count: count, level: level, avoid: avoid)),
    ];

    var latency = 0;
    var discarded = 0;
    var attempts = 0;

    // 第一次
    attempts++;
    final r1 = await _run(messages, level);
    latency += r1.latencyMs;
    discarded += r1.discarded;
    var best = r1.items;
    var err = r1.error;

    // 合格数不够就打回重做一次（说清为什么，和 solver 一个路子）
    if (best.length < count) {
      attempts++;
      final retryMessages = [
        ...messages,
        LlmMessage('user',
            '刚才只给出了 ${best.length} 道合格题目（要求 $count 道）。'
            '请检查：答案和 equation 本地复算是否一致、讲解是否至少 2 步、'
            '题干是否含"如图/下表"、是否和已出过的题重复。'
            '重新出满 $count 道，只输出 JSON。'),
      ];
      final r2 = await _run(retryMessages, level);
      latency += r2.latencyMs;
      discarded += r2.discarded;
      if (r2.items.length > best.length || best.isEmpty) {
        best = r2.items;
        err = r2.error;
      }
    }

    return QuizGenResult(
      questions: best,
      error: best.isEmpty ? (err ?? '模型没有给出合格题目') : null,
      attempts: attempts,
      latencyMs: latency,
      discarded: discarded,
    );
  }

  String _userPrompt({
    required int grade,
    String? unit,
    required int count,
    required QuizLevel level,
    required List<String> avoid,
  }) {
    final b = StringBuffer()
      ..writeln('（$grade 年级）难度档：${level.label} —— ${level.brief}')
      ..writeln('知识点范围：${(unit == null || unit.trim().isEmpty) ? '不限定，选该年级任何合适内容' : unit}')
      ..writeln('请出 $count 道题。');
    if (avoid.isNotEmpty) {
      b.writeln('已出过的题（不要重复出）：');
      for (final s in avoid.take(20)) {
        b.writeln('- $s');
      }
    }
    return b.toString();
  }

  /// 一次调用 + 解析 + 逐道过闸门。
  Future<_RunResult> _run(List<LlmMessage> messages, QuizLevel level) async {
    try {
      // 上限不是预扣：推理模型要先花几百 token 想思路再输出 JSON。
      // 出题比讲解更费 token —— 实测（deepseek-v4-flash，奥数档 4 题）
      // 4000 会被思维链吃光、正文一个字符都没输出就 finish=length。
      // 8000 是实测能稳定出完 4 道奥数题的量；用不到不花钱。
      final reply = await client.chat(
        messages,
        temperature: level == QuizLevel.olympiad ? 0.95 : 0.85,
        maxTokens: 8000,
      );
      final parsed = _parse(reply.text);
      final kept = <GenQuestion>[];
      for (final it in parsed) {
        final q = _accept(it, level);
        if (q != null) kept.add(q);
      }
      return _RunResult(kept, parsed.length - kept.length, null, reply.latencyMs);
    } on LlmError catch (e) {
      return _RunResult(const [], 0, e.message, 0);
    } catch (e) {
      return _RunResult(const [], 0, 'AI 出题失败：$e', 0);
    }
  }

  /// 单道题的本地闸门。返回 null = 丢弃。
  ///
  /// 顺序有讲究：先看"能不能验算"，再看"讲没讲全"，最后才收数值。
  GenQuestion? _accept(_Item it, QuizLevel level) {
    final stem = it.stem.trim();
    if (stem.length < 6 || stem.length > 300) return null;

    // 需要看图/表的题：本地画不出模型心里那张配图，出了也是废题
    final banned = RegExp(r'如图|下图|上图|看图|统计表|条形|折线|扇形|表格|数轴');
    if (banned.hasMatch(stem)) return null;

    // 讲解至少 2 步（和讲解 Agent 同一标准：一步到位的题没有讲解价值）
    final steps = it.steps.map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
    if (steps.length < 2) return null;
    if (steps.any((s) => s.length > 120)) return null;

    // 答案必须能本地复算
    final eq = it.equation.trim();
    if (eq.isEmpty) return null;
    final local = ExprEval.eval(eq);
    if (local == null) return null;
    if (local.isNegative) return null;
    if (!local.hasFiniteDecimal) return null; // 循环小数不出
    // 数值过大（>10^9）的题没有练习价值
    if (local.toDouble().abs() > 1e9) return null;

    final claimed = Rational.tryParse(it.answer.trim());
    if (claimed == null) return null; // 答案不是数（"能/不能"类）不出
    if (!ExprEval.matches(local, claimed)) return null; // 模型自己都不认同 → 丢

    final diff = it.difficulty.clamp(1, 5);
    // 难度档与自评严重脱节时，以档位为准（模型经常把奥数题自评成 2）
    final floor = switch (level) {
      QuizLevel.basic => 1,
      QuizLevel.boost => 3,
      QuizLevel.olympiad => 4,
    };
    return GenQuestion(
      stem: stem,
      answer: local.toString(),
      value: local.toDouble(),
      unit: it.unit.trim(),
      steps: steps,
      difficulty: math.max(diff, floor),
      kp: it.kp.trim(),
      equation: eq,
    );
  }

  List<_Item> _parse(String text) {
    var t = text.trim();
    if (t.startsWith('```')) {
      t = t.replaceFirst(RegExp(r'^```(json)?'), '').trim();
      if (t.endsWith('```')) t = t.substring(0, t.length - 3).trim();
    }
    final a = t.indexOf('{');
    final b = t.lastIndexOf('}');
    if (a < 0 || b <= a) return const [];
    try {
      final j = jsonDecode(t.substring(a, b + 1)) as Map<String, Object?>;
      final list = (j['items'] as List?) ?? const [];
      final out = <_Item>[];
      for (final e in list) {
        if (e is! Map) continue;
        out.add(_Item(
          stem: (e['stem'] ?? '').toString(),
          answer: (e['answer'] ?? '').toString(),
          unit: (e['unit'] ?? '').toString(),
          equation: (e['equation'] ?? '').toString(),
          steps: ((e['steps'] as List?) ?? const [])
              .map((s) => s.toString())
              .toList(),
          kp: (e['kp'] ?? '').toString(),
          difficulty: int.tryParse((e['difficulty'] ?? '').toString()) ?? 3,
        ));
      }
      return out;
    } catch (_) {
      return const [];
    }
  }
}

class _RunResult {
  final List<GenQuestion> items;
  final int discarded;
  final String? error;
  final int latencyMs;
  const _RunResult(this.items, this.discarded, this.error, this.latencyMs);
}

class _Item {
  final String stem;
  final String answer;
  final String unit;
  final String equation;
  final List<String> steps;
  final String kp;
  final int difficulty;
  const _Item({
    required this.stem,
    required this.answer,
    required this.unit,
    required this.equation,
    required this.steps,
    required this.kp,
    required this.difficulty,
  });
}

/// 把模型自称的知识点落到具体考点；落不上就退回单元名或"综合应用"。
///
/// **年级卡死**：只接受与请求年级一致的考点。模型经常自称一个该年级
/// 没有的知识点（五年级的卷子自称"分数除法"），"就近取年级"会取到六年级去，
/// 卷子上就出现"五年级的题挂着六上标签"。宁可标"综合应用"，
/// 也不挂错年级 —— 家长看到错年级标签，比没有标签更糟。
String classifyKp(String kp, {required int grade, String? unit}) {
  final idx = KnowledgeIndex();
  final r = idx.match(knowledgePoint: kp, grade: grade);
  if (r.point != null && r.point!.grade == grade) return r.point!.path;
  final u = idx.match(knowledgePoint: unit, grade: grade);
  if (u.point != null && u.point!.grade == grade) return u.point!.path;
  if (unit != null && unit.trim().isNotEmpty) return unit.trim();
  return '综合应用';
}

/// 题干归一化后比较：标点、空格不该影响"是不是同一道题"。
String stemKey(String stem) => stem
    .replaceAll(RegExp(r'\s+'), '')
    .replaceAll(RegExp(r'[，。、？！,?.!]'), '');

/// 把一道过了闸门的 AI 题补全成 QuizQuestion。
///
/// 系统补全的部分：知识点归类（本地 KnowledgeIndex，年级优先）、
/// 判分配置、稳定 id（题干哈希，错题本归档/重放都认它）。
/// 答案**不在这里产生** —— [GenQuestion.answer] 已经是本地复算值。
QuizQuestion toQuizQuestion(GenQuestion g, {required int grade, String? unit}) {
  return QuizQuestion(
    id: 'ai-${g.stem.hashCode.abs().toRadixString(36)}',
    kpPath: classifyKp(g.kp, grade: grade, unit: unit),
    stem: g.stem,
    solutionSteps: g.steps,
    answer: QuizAnswer(
      display: g.answer,
      value: g.value,
      unit: g.unit,
    ),
    kind: 'ai-app',
    grade: grade,
    difficulty: g.difficulty,
    source: 'ai',
  );
}

/// 混卷：AI 题在前，本地题补足，题干去重，**绝不为空**。
///
/// [moreLocal] 在本地题不够时再抽一轮（AI 少出是常态：它有闸门，
/// 会丢掉不合格的题）。调用方（App / Web 服务）共用这一份逻辑，
/// 避免两边各写一遍、日后行为不一致。
List<QuizQuestion> mixPaper({
  required List<QuizQuestion> local,
  required List<GenQuestion> ai,
  required int count,
  required int grade,
  String? unit,
  required List<QuizQuestion> Function(int n) moreLocal,
}) {
  final out = <QuizQuestion>[];
  final seen = <String>{};
  for (final g in ai) {
    if (out.length >= count) break;
    final q = toQuizQuestion(g, grade: grade, unit: unit);
    if (seen.add(stemKey(q.stem))) out.add(q);
  }
  for (final q in local) {
    if (out.length >= count) break;
    if (seen.add(stemKey(q.stem))) out.add(q);
  }
  var guard = 0;
  while (out.length < count && guard < 40) {
    guard++;
    final extra = moreLocal(count - out.length);
    if (extra.isEmpty) break;
    for (final q in extra) {
      if (out.length >= count) break;
      if (seen.add(stemKey(q.stem))) out.add(q);
    }
  }
  return out;
}
