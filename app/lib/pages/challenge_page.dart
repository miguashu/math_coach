import 'package:flutter/material.dart';

import 'package:math_coach/ai/adopt.dart';
import 'package:math_coach/ai/variants.dart';
import 'package:math_coach/quiz/question.dart';
import 'package:math_coach/store/repository.dart';
import 'package:math_coach/variant/generator.dart';
import 'package:math_coach/variant/mapping.dart';

import '../state.dart';
import '../widgets/question_card.dart';

/// 变体闯关：把错题"换个数字"再练一遍。
///
/// 为什么要有它：错题本里反复练**同一道题**，孩子会把答案背下来 ——
/// 重要度归零不代表会了，只是记住了那几个数字。
/// 变体做的是同一类题换一组数字，答案仍然本地算（`lib/variant` 的闸门保证不出退化题），
/// 这样才算真的在考"方法会不会"，而不是"记不记得"。
///
/// 入口在错题本：每条记录一个「闯关」按钮。
///
/// 2026-10-17 家长反馈："错题本变体闯关都是固定的分数相加减。可以异步生成。"
/// 两处都改了：
///
/// 1. **不再是固定的分数加减**。原来只要题型名映射不上（23 个题型里一半如此），
///    就直接按年级兜底，而五年级兜底写死是分数加减。现在按优先级来：
///    ① 严格映射（带算法结构，面积≠周长，衍生题那套）；
///    ② 宽松映射（只看题型名）；
///    ③ **按题干认**（`variantRecipeByStem`：题干里的"周长/面积/倍/找回/余数"都是线索）；
///    ④ 年级兜底，且**在一组里轮换**（`fallbackVariantKind(grade, salt:)`）。
///    走到第 ④ 步的题，卡片上会标「同年级常规练习」—— 不出不相干的题还不说明。
/// 2. **异步生成**。本地能映射的毫秒级先上屏；映射不上的（混合运算、植树、立体图形……）
///    排队在后台问模型，出来再补上，页面不用干等。没配 key 就走轮换兜底。
class ChallengePage extends StatefulWidget {
  final AppState state;
  final List<ReviewRecord> sources;

  /// 一组出几道（一个来源出 [perSource] 道，最多 [total] 道）。
  final int perSource;
  final int total;

  const ChallengePage({
    super.key,
    required this.state,
    required this.sources,
    this.perSource = 3,
    this.total = 6,
  });

  @override
  State<ChallengePage> createState() => _ChallengePageState();
}

class _ChallengePageState extends State<ChallengePage> {
  late final List<_ChallengeItem> _items;

  /// 本地没有同算法模板、要问模型的题（异步补）。
  final List<ReviewRecord> _pending = [];
  final Map<String, TextEditingController> _ctl = {};
  final Map<String, bool> _verdicts = {};
  bool _submitted = false;
  bool _recorded = false;
  bool _aiBusy = false;
  String? _aiNote;

  /// 兜底轮换用：每轮闯关 +1，同一年级不会每次都落到同一个模板。
  int _round = 0;

  @override
  void initState() {
    super.initState();
    _items = _build();
    for (final it in _items) {
      _ctl[it.q.id] = TextEditingController();
    }
    // 异步补 AI 同类题：不挡页面打开（本地题已经能做了）
    WidgetsBinding.instance.addPostFrameCallback((_) => _fillPending());
  }

  @override
  void dispose() {
    for (final c in _ctl.values) {
      c.dispose();
    }
    super.dispose();
  }

  /// 这道错题该出什么样的变体：严格 → 宽松 → 按题干认。都认不出返回 null。
  ///
  /// 顺序有讲究：**能严格就严格**。面积题走到宽松映射会变成"面积或周长随机"，
  /// 那正是 M12 修掉的"衍生题换了算法"——闯关虽然不要求和衍生题一样严，
  /// 但认得出的结构没理由不用。
  ({VariantKind kind, VariantShape? shape})? _recipeFor(ReviewRecord src) {
    final strict = localRecipeFor(quizKind: src.kind, stem: src.stem);
    if (strict != null) return (kind: strict.kind, shape: strict.shape);
    final loose = variantKindFor(src.kind);
    if (loose != null) return (kind: loose, shape: null);
    return variantRecipeByStem(src.stem, kpPath: src.kpPath);
  }

  List<_ChallengeItem> _build() {
    final gen = VariantGenerator(seed: DateTime.now().microsecondsSinceEpoch);
    final out = <_ChallengeItem>[];
    final seen = <String>{};
    _pending.clear();

    for (final src in widget.sources) {
      if (out.length >= widget.total) break;
      final recipe = _recipeFor(src);
      if (recipe == null) {
        // 本地没有同算法模板：排队问模型，别用不相干的题充数
        _pending.add(src);
        continue;
      }
      final kind = recipe.kind;
      final vs = gen.generateMany(
        kind,
        widget.perSource,
        grade: src.grade,
        shape: recipe.shape,
      );
      for (final v in vs) {
        if (out.length >= widget.total) break;
        final sig = v.params.entries.map((e) => '${e.key}=${e.value}').join('|');
        if (!seen.add('${kind.name}|$sig')) continue;
        out.add(_item(
          v: v,
          kind: kind,
          grade: src.grade,
          difficulty: src.difficulty,
          sourceStem: src.stem,
          loose: false,
        ));
      }
    }
    return out;
  }

  /// 把本地生成的变体转成能判分/归档的题。
  _ChallengeItem _item({
    required Variant v,
    required VariantKind kind,
    required int grade,
    required int difficulty,
    required String sourceStem,
    required bool loose,
  }) {
    final sig = v.params.entries.map((e) => '${e.key}=${e.value}').join('|');
    return _ChallengeItem(
      v: v,
      kind: kind,
      loose: loose,
      q: QuizQuestion(
        id: 'chal-${kind.name}-${sig.hashCode.abs()}',
        kpPath: loose ? '${kind.label} · 同年级常规练习' : '${kind.label} · 变体',
        kpCode: kind.defaultCode,
        stem: v.displayStem,
        // 变体是新数字，不能直接套原题的讲解（里面的数字对不上），
        // 所以只给一句提示，真正的讲解留给「看原题」。
        solutionSteps: const ['这是同类题，数字换了，做法和原来一样。'],
        answer: QuizAnswer(
          display: v.displayAnswer,
          value: v.answer.toDouble(),
          unit: v.answerUnit,
        ),
        kind: 'variant_${kind.name}',
        grade: grade,
        difficulty: difficulty,
      ),
      sourceStem: sourceStem,
    );
  }

  /// 后台问模型，给本地没模板的错题补同类题。
  ///
  /// 模型出的题同样要过 VariantAgent 里那几道闸门（给验算式 + 本地复算一致），
  /// 所以这里拿到的题答案已经是验过的。单道失败不拖累其他题。
  Future<void> _fillPending() async {
    if (_pending.isEmpty || _items.length >= widget.total) return;
    if (!widget.state.aiConfig.chatReady) {
      // 没配 key：就地轮换兜底，别让页面空着，但要说清楚
      _fallbackFill(reason: '还没配 AI key，先出几道同年级的常规题练着');
      return;
    }
    setState(() {
      _aiBusy = true;
      _aiNote = '有 ${_pending.length} 道题本地没有同类模板，正在用 AI 现场出…';
    });
    final agent = VariantAgent(widget.state.llm());
    var added = 0;
    for (final src in _pending) {
      if (_items.length >= widget.total) break;
      try {
        final list = await agent.generate(
          src.stem,
          n: widget.perSource,
          grade: src.grade,
        );
        for (final g in list) {
          if (_items.length >= widget.total) break;
          if (_items.any((e) => e.q.stem == g.stem)) continue;
          final q = AdoptedQuestion.fromGen(
            g,
            grade: src.grade,
            kpPath: 'AI 同类题',
          );
          _ctl[q.id] = TextEditingController();
          _items.add(_ChallengeItem(
            v: null,
            kind: null,
            loose: false,
            q: q,
            sourceStem: src.stem,
            ai: true,
          ));
          added++;
        }
      } catch (_) {
        // 这道问不出来：继续问下一道，最后统一兜底
      }
    }
    if (!mounted) return;
    setState(() {
      _aiBusy = false;
      _aiNote = added > 0 ? '补了 $added 道 AI 现场出的同类题（答案已本地验算）' : null;
    });
    if (_items.isEmpty) {
      _fallbackFill(reason: 'AI 也没出成，先出几道同年级的常规题练着');
    }
  }

  /// 兜底：按年级在一组模板里**轮换**（不再万年分数加减），并标注"同年级常规练习"。
  void _fallbackFill({required String reason}) {
    final gen = VariantGenerator(seed: DateTime.now().microsecondsSinceEpoch);
    final out = <_ChallengeItem>[];
    final seen = <String>{};
    for (var i = 0; i < widget.sources.length; i++) {
      if (_items.length + out.length >= widget.total) break;
      final src = widget.sources[i];
      final kind = fallbackVariantKind(src.grade, salt: i + _round);
      final vs = gen.generateMany(kind, widget.perSource, grade: src.grade);
      for (final v in vs) {
        if (_items.length + out.length >= widget.total) break;
        final sig = v.params.entries.map((e) => '${e.key}=${e.value}').join('|');
        if (!seen.add('${kind.name}|$sig')) continue;
        out.add(_item(
          v: v,
          kind: kind,
          grade: src.grade,
          difficulty: src.difficulty,
          sourceStem: src.stem,
          loose: true,
        ));
      }
    }
    if (!mounted) return;
    setState(() {
      _items.addAll(out);
      _aiNote = out.isEmpty ? null : '$reason（不是原题的同类型，标着「常规」）';
    });
  }

  Future<void> _submit() async {
    for (final it in _items) {
      final input = _ctl[it.q.id]?.text.trim() ?? '';
      final correct = input.isNotEmpty && it.q.answer.check(input);
      _verdicts[it.q.id] = correct;
    }
    setState(() => _submitted = true);
  }

  /// 归档：答完就把结果写进错题本，错的会进复习队列。
  ///
  /// 这是变体闯关和"随便做几道题"的区别 —— 练完要留下痕迹，
  /// 否则孩子做对了也不会被安排复习，做错了也不会再出现。
  Future<void> _record() async {
    if (_recorded) return;
    _recorded = true;
    await widget.state.recordChallenge({
      for (final it in _items) it.q: _verdicts[it.q.id] ?? false,
    });
  }

  void _again() {
    _round++;
    Navigator.of(context).pushReplacement(MaterialPageRoute<void>(
      builder: (_) => ChallengePage(state: widget.state, sources: widget.sources),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final correct = _verdicts.values.where((e) => e).length;

    return Scaffold(
      appBar: AppBar(
        title: Text(_submitted ? '闯关结果 $correct / ${_items.length}' : '变体闯关'),
        backgroundColor: const Color(0xFF1D4ED8),
        foregroundColor: Colors.white,
        actions: [
          if (_submitted)
            TextButton(
              onPressed: _again,
              child: const Text('再来一组', style: TextStyle(color: Colors.white)),
            ),
        ],
      ),
      body: _items.isEmpty && _pending.isEmpty
          ? _EmptyChallenge(sources: widget.sources)
          : Column(
              children: [
                if (!_submitted)
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                    color: const Color(0xFFEFF6FF),
                    child: Text(
                      _pending.isNotEmpty && _items.isEmpty
                          ? '这些题本地没有同类模板，正在用 AI 按原题出…'
                          : '下面都是同类题，换了数字。做法一样 —— 想不起来就看一眼原题。',
                      style: const TextStyle(fontSize: 12.5, color: Color(0xFF1E40AF), height: 1.5),
                    ),
                  ),
                if (_aiBusy || _aiNote != null)
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.fromLTRB(14, 8, 14, 10),
                    color: const Color(0xFFF8FAFC),
                    child: Row(
                      children: [
                        if (_aiBusy)
                          const SizedBox(
                              width: 13, height: 13, child: CircularProgressIndicator(strokeWidth: 2))
                        else
                          const Icon(Icons.info_outline, size: 14, color: Color(0xFF64748B)),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(_aiNote ?? '',
                              style: const TextStyle(fontSize: 11.5, color: Color(0xFF475569))),
                        ),
                      ],
                    ),
                  ),
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.only(bottom: 20, top: 6),
                    children: [
                      for (var i = 0; i < _items.length; i++)
                        QuestionCard(
                          q: _items[i].q,
                          indexLabel: _items[i].label(i + 1),
                          controller: _ctl[_items[i].q.id],
                          correct: _submitted ? (_verdicts[_items[i].q.id] ?? false) : null,
                        ),
                      if (_submitted)
                        for (final it in _items)
                          if (_verdicts[it.q.id] == false) _WrongHint(item: it),
                    ],
                  ),
                ),
                SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(14, 8, 14, 12),
                    child: SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        onPressed: _submitted || _items.isEmpty
                            ? () async {
                                await _record();
                                if (!mounted) return;
                                Navigator.of(context).pop();
                              }
                            : _submit,
                        child: Text(_submitted ? '完成（错的进错题本）' : '提交'),
                      ),
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}

class _ChallengeItem {
  final Variant? v;
  final VariantKind? kind;

  /// true = 年级兜底出来的，**不是原题的同类型**（界面上要标出来）。
  final bool loose;

  /// true = AI 现场出的同类题。
  final bool ai;

  final QuizQuestion q;
  final String sourceStem;

  const _ChallengeItem({
    required this.v,
    required this.kind,
    required this.loose,
    required this.q,
    required this.sourceStem,
    this.ai = false,
  });

  /// 卡片标题：第几题 + 什么类型；兜底题明确标「常规」，AI 题标「AI」。
  String label(int index) {
    final parts = <String>['第 $index 题'];
    if (ai) {
      parts.add('AI 同类题');
    } else if (loose) {
      parts.add('${kind?.label ?? ''} · 常规');
    } else if (kind != null) {
      parts.add(kind!.label);
    }
    return parts.join(' · ');
  }
}

/// 答错时给一条"回原题"的线索，不直接给答案。
class _WrongHint extends StatelessWidget {
  final _ChallengeItem item;
  const _WrongHint({required this.item});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
      padding: const EdgeInsets.all(11),
      decoration: BoxDecoration(
        color: const Color(0xFFFEF2F2),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFFECACA)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('这题没过 · 回原题想想',
              style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700,
                  color: Color(0xFFB91C1C))),
          const SizedBox(height: 4),
          Text(item.sourceStem,
              style: const TextStyle(fontSize: 12.5, color: Color(0xFF7F1D1D), height: 1.5)),
          const SizedBox(height: 6),
          Text('正确答案：${item.q.answer.display}${item.q.answer.unit}',
              style: const TextStyle(fontSize: 12.5, color: Color(0xFF991B1B))),
        ],
      ),
    );
  }
}

/// 一个变体都没生成出来时的兜底：说清楚原因，并给回退路径。
class _EmptyChallenge extends StatelessWidget {
  final List<ReviewRecord> sources;
  const _EmptyChallenge({required this.sources});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 44),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.extension_outlined, size: 44, color: Color(0xFF94A3B8)),
            const SizedBox(height: 12),
            const Text(
              '这几道题暂时出不了变体。\n',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
              textAlign: TextAlign.center,
            ),
            Text(
              '变体生成器只覆盖了 9 类题型（四则运算、面积、单位换算、价钱应用题等）。\n'
              '立体图形、展开图、混合运算这类要么问 AI，要么还没有模板。\n\n'
              '可以直接回错题本「重做前 6 题」练原题。',
              style: const TextStyle(fontSize: 12.5, color: Color(0xFF64748B), height: 1.6),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
