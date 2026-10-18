/// 错题衍生题 Agent：判卷结束后，为每道错题造几道同类题，进「衍生题库」。
///
/// 两条路，**本地优先**：
///
///  1. **本地模板**（`lib/variant`）：错题的题型能严格映射到一个变体模板
///     **且算法结构一致**时，直接改数字本地出题，答案由 `Rational` 精确算出
///     —— 不走网络、不可能出错。绝大部分错题（四则运算、面积周长、
///     单位换算、价钱应用题）走这条。
///  2. **模型按原题干出**：立体图形、展开图、圆柱、分数乘法、以及 AI 现场出的
///     应用题 —— 本地没有"同算法"的模板，就把原题干交给模型出同类题。
///     这条路的门槛比"同类题"功能更严：**必须给得出验算式且本地复算一致**，
///     否则整道丢弃 —— 因为进题库的题会被反复练，一个错答案会被练很多遍。
///     宁可一道都不进，也不让一道答案错的题住进题库。
///
/// **本地这条路也要卡"算法结构"**（见 [localRecipeFor]）：
/// 只按题型名映射会出"面积错题衍生出周长题""减法错题衍生出加法题"这种事 ——
/// 答案本身没错，但孩子练的是另一个考点，连对两次会在题库里留下假的"已掌握"。
/// 所以本地衍生要带处方（模板 + 必须保持的结构），模板照结构出；
/// 判不出结构就退回模型，不许猜。
///
/// 为什么要这么严：题库是**持久**的。错题本里答错一次只是丢一条记录，
/// 题库里躺一道错答案，孩子每次练都在巩固一个错误。
library;

import '../core/rational.dart';
import '../quiz/question.dart';
import '../store/bank.dart';
import '../variant/generator.dart';
import '../variant/mapping.dart';
import 'expr.dart';
import 'llm.dart';
import 'variants.dart';

/// 一次衍生的结果。
class DeriveOutcome {
  final List<BankEntry> entries;

  /// 哪几道错题没能衍生出来（错题 id → 人话原因）。
  /// **不假装成功**：出不来就说清楚为什么，家长才有得选（配 key / 手动练原题）。
  final Map<String, String> skipped;

  /// 有多少道用了模型（0 = 全是本地出的）
  final int aiCount;

  const DeriveOutcome({
    required this.entries,
    required this.skipped,
    required this.aiCount,
  });

  bool get ok => entries.isNotEmpty;

  static const empty = DeriveOutcome(entries: [], skipped: {}, aiCount: 0);
}

class DeriveAgent {
  /// 没配 key 时为 null：那就只走本地模板这条路，不报错、不假装。
  final LlmPort? client;

  /// 固定种子只给测试用；线上留空 = 每次衍生都是新数字。
  final int? seed;

  DeriveAgent({this.client, this.seed});

  /// 每道错题造几道。
  ///
  /// 3 道是权衡过的：1 道像是"再来一遍"，练不到方法；
  /// 5 道以上家长会觉得"怎么又这么多题"。3 道刚好能看出是"换个数字也会"。
  static const perQuestion = 3;

  /// 一次判卷最多为几道错题问模型（一次请求里批量问，不是一道一次请求）。
  static const _maxAiSources = 6;

  /// 题干里出现这些词说明这题需要配图，纸面上没有图孩子看不懂 —— 一律不收。
  static final _banned = RegExp(r'如图|下图|上图|看图|统计表|统计图|条形|折线|扇形|表格|数轴|下图');

  /// 给一批错题各造几道衍生题。**不抛异常**：网络挂了也要把本地出的题带回来。
  Future<DeriveOutcome> deriveAll(List<QuizQuestion> wrong) async {
    if (wrong.isEmpty) return DeriveOutcome.empty;
    final now = DateTime.now();
    final entries = <BankEntry>[];
    final skipped = <String, String>{};
    final needAi = <QuizQuestion>[];
    final seen = <String>{};

    // ── 第一路：本地模板 ──────────────────────────────
    for (final src in wrong) {
      final recipe = localRecipeFor(quizKind: src.kind, stem: src.stem);
      if (recipe == null) {
        needAi.add(src);
        continue;
      }
      final local = _local(src, recipe, now);
      if (local.isEmpty) {
        needAi.add(src);
        continue;
      }
      for (final e in local) {
        if (seen.add(e.id)) entries.add(e);
      }
    }

    // ── 第二路：模型按原题干出（本地没模板的才走这里）────────
    if (needAi.isNotEmpty) {
      if (client == null) {
        for (final s in needAi) {
          skipped[s.id] = '这类题本地没有同类模板（立体图形/展开图/圆柱等），'
              '到「设置 → AI」配好 key 就能让模型按原题出';
        }
      } else {
        try {
          final ai = await _ai(needAi, now);
          for (final e in ai.entries) {
            if (seen.add(e.id)) entries.add(e);
          }
          skipped.addAll(ai.skipped);
        } catch (e) {
          for (final s in needAi) {
            skipped[s.id] = '模型出题失败：$e';
          }
        }
      }
    }

    // 本地和模型都没能覆盖到的，给一句兜底原因 —— 不能让家长对着"0 道"发呆
    for (final src in wrong) {
      final got = entries.any((e) => e.sourceQuestionId == src.id);
      if (!got) skipped.putIfAbsent(src.id, () => '这道题暂时没造出衍生题');
    }

    if (entries.isEmpty) {
      return DeriveOutcome(entries: const [], skipped: skipped, aiCount: 0);
    }
    return DeriveOutcome(
      entries: entries,
      skipped: skipped,
      aiCount: entries.where((e) => e.isAi).length,
    );
  }

  // ── 本地 ────────────────────────────────────────────────

  /// 本地这条路：**照处方出题**。
  ///
  /// 处方里带着"必须保持的算法结构"，模板会照着出 ——
  /// 源题问面积就只出面积、源题是减法就只出减法。
  /// 换了结构等于换了考点，孩子连对两次也说明不了原题会了。
  List<BankEntry> _local(QuizQuestion src, LocalRecipe recipe, DateTime now) {
    final gen = VariantGenerator(
        seed: seed ?? DateTime.now().microsecondsSinceEpoch);
    final vs = gen.generateMany(recipe.kind, perQuestion,
        grade: src.grade, shape: recipe.shape);
    return [
      for (final v in vs)
        BankEntry(
          id: QuestionBank.idFor(v.displayStem),
          sourceQuestionId: src.id,
          sourceStem: src.stem,
          stem: v.displayStem,
          answer: v.displayAnswer,
          answerValue: v.answer.toDouble(),
          unit: v.answerUnit,
          steps: const ['这是同一类题，数字换了，做法和原题一样。想不起来就看一眼原题。'],
          kpPath: src.kpPath.isEmpty ? recipe.kind.label : src.kpPath,
          kpCode: v.knowledgeCode ?? src.kpCode,
          grade: src.grade,
          difficulty: src.difficulty,
          origin: 'local',
          createdAt: now,
        ),
    ];
  }

  // ── 模型 ────────────────────────────────────────────────

  static const _system = '''
你是小学数学出题老师。用户刚批改完一张卷子，下面列出孩子**做错**的题。
请为每一道错题出同类练习题：换数字、换情境，考同一个知识点、同样的解法。

硬性要求：
1. 每道题必须标明是给哪一道原题出的：for 填原题编号（1、2、3……）。
2. 答案必须是整数或有限小数；不出负数、不出循环小数。
3. **每题必须给出一条从条件到答案的完整四则算式**（只含数字和 + - * / ( )）。
   系统会拿它本地复算你的答案，算不出或对不上的题会被直接丢弃。
   只写算式本身，不要写等号和答案（写 "20-5"，不要写 "20-5=15"）。
4. 题干**不许**出现"如图""下图""上图""下表""统计表""统计图""数轴"这类说法
   —— 这些题印在纸上没有配图，孩子看不懂。
5. 同一道原题的几道练习题之间不要重复，数字要真的换掉，别只改一个字。
6. hint 写一句解题提示，点方法不点答案（例如"先算出一盒多少钱"）。

只输出 JSON，不要其他文字：
{"items":[{"for":1,"stem":"题目","answer":"答案数字","unit":"单位或空","equation":"算式","hint":"一句提示"}]}''';

  Future<({List<BankEntry> entries, Map<String, String> skipped})> _ai(
      List<QuizQuestion> srcs, DateTime now) async {
    final list = srcs.take(_maxAiSources).toList();
    final skipped = <String, String>{};
    for (final s in srcs.skip(_maxAiSources)) {
      skipped[s.id] = '这次错题较多，先给前 $_maxAiSources 道造了衍生题；'
          '剩下的下次会自动补上';
    }

    final buf = StringBuffer();
    for (var i = 0; i < list.length; i++) {
      final q = list[i];
      buf.writeln('【原题 ${i + 1}】（${q.grade} 年级 / ${q.kpPath}）${q.stem}');
    }
    final reply = await client!.chat(
      [
        const LlmMessage('system', _system),
        LlmMessage('user',
            '$buf\n请为上面每一道原题各出 $perQuestion 道同类题，for 填对应的原题编号。'),
      ],
      temperature: 0.8,
      // 上限而非预扣：思维链会把预算吃光，给宽裕才不会让正文被挤没（出题踩过一次）
      maxTokens: 8000,
    );

    final raws = VariantAgent.parseReply(reply.text);
    final byFor = <int, List<BankEntry>>{};
    final usedStems = <String>{};
    for (final r in raws) {
      final idx = r.forIndex - 1;
      // 只有一道原题时模型常常不写 for，就当成第 1 道（不然整批白跑）
      final target = (list.length == 1 && r.forIndex == 0) ? 0 : idx;
      if (target < 0 || target >= list.length) continue;
      final bucket = byFor.putIfAbsent(target, () => []);
      if (bucket.length >= perQuestion) continue;
      final e = _accept(list[target], r, now);
      if (e == null) continue;
      if (!usedStems.add(e.id)) continue;
      bucket.add(e);
    }

    final entries = <BankEntry>[];
    for (var i = 0; i < list.length; i++) {
      final got = byFor[i] ?? const <BankEntry>[];
      if (got.isEmpty) {
        skipped[list[i].id] =
            '模型没给出能通过本地验算的同类题（题都丢弃了，宁可不进也不出错题）';
        continue;
      }
      entries.addAll(got);
    }
    return (entries: entries, skipped: skipped);
  }

  /// 收一道模型出的衍生题 —— **这是这条路上唯一的闸门**。
  ///
  /// 五道关，缺一不可：题干不许要配图、必须给验算式、算式能解析、
  /// 本地复算与模型自报答案一致、答案不是无限小数。
  BankEntry? _accept(QuizQuestion src, RawVariant r, DateTime now) {
    final stem = r.stem.trim();
    if (stem.isEmpty || r.answer.trim().isEmpty) return null;
    if (_banned.hasMatch(stem)) return null;

    final eq = r.equation.trim();
    if (eq.isEmpty) return null;
    final v = ExprEval.eval(eq);
    if (v == null) return null;

    final a = Rational.tryParse(r.answer.trim());
    if (a == null) return null;
    if (!ExprEval.matches(v, a)) return null;
    if (!a.hasFiniteDecimal) return null;

    final unit = r.unit.trim();
    final hint = r.hint.trim();
    return BankEntry(
      id: QuestionBank.idFor(stem),
      sourceQuestionId: src.id,
      sourceStem: src.stem,
      stem: stem,
      answer: unit.isEmpty ? _fmt(a) : '${_fmt(a)}$unit',
      answerValue: a.toDouble(),
      unit: unit,
      steps: [hint.isEmpty ? '这是同一类题，做法和原题一样。' : hint],
      kpPath: src.kpPath,
      kpCode: src.kpCode,
      grade: src.grade,
      difficulty: src.difficulty,
      origin: 'ai',
      createdAt: now,
    );
  }

  static String _fmt(Rational r) =>
      r.isInteger ? r.toMixedString() : r.toDouble().toString();
}
