/// 练衍生题：把题库里的一批题当普通卷子做一遍。
///
/// 和「变体闯关」的区别：
///   - 变体闯关是**现场**生成（每次点都换新数字），练完即走；
///   - 这里是练**题库里已经存好的**题 —— 家长和孩子看到的是同一批题，
///     做完会记在题库上（连对两次过关），答错的还会进错题本和复习队列。
///
/// 判分照旧是本地判（`QuizAnswer.check`），讲解用的是生成时就带好的提示，
/// 所以离线也能练、答案不会错 —— 入库的题都过了本地验算（见 lib/ai/derive.dart）。
library;

import 'package:flutter/material.dart';

import 'package:math_coach/store/bank.dart';

import '../state.dart';
import '../widgets/question_card.dart';

class BankPracticePage extends StatefulWidget {
  final AppState state;
  final List<BankEntry> items;

  /// 这几道题的来源错题题干（非空时在顶部提示"想不起来看原题"）
  final String? groupStem;

  const BankPracticePage({
    super.key,
    required this.state,
    required this.items,
    this.groupStem,
  });

  @override
  State<BankPracticePage> createState() => _BankPracticePageState();
}

class _BankPracticePageState extends State<BankPracticePage> {
  final Map<String, TextEditingController> _ctl = {};

  /// 交卷那一刻的作答快照。
  ///
  /// 落账读它、不读 controller（2026-10-17 修）：controller 是**界面**的东西，
  /// 谁在重建时动它一下都合法，拿它当"孩子写了什么"的唯一来源太脆 ——
  /// 之前就是这么丢过一次：交卷后重建把输入框清空，`_record()` 读到的全是空串，
  /// 于是 3 道题一条痕迹都没记上，界面上还看不出任何异常。
  /// 快照在交卷时定死，之后界面怎么重建都不影响落账。
  final Map<String, String> _answers = {};
  final Map<String, bool> _verdicts = {};
  bool _submitted = false;
  bool _recorded = false;
  String? _note;

  @override
  void initState() {
    super.initState();
    for (final e in widget.items) {
      _ctl[e.id] = TextEditingController();
    }
  }

  @override
  void dispose() {
    for (final c in _ctl.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _submit() async {
    FocusManager.instance.primaryFocus?.unfocus();
    var blank = 0;
    for (final e in widget.items) {
      final t = _ctl[e.id]?.text.trim() ?? '';
      _answers[e.id] = t;
      if (t.isEmpty) {
        blank++;
        continue;
      }
      _verdicts[e.id] = e.toQuestion().answer.check(t);
    }
    setState(() {
      _submitted = true;
      _note = blank > 0 ? '有 $blank 道没作答，这次不算（不算错也不算对）' : null;
    });
  }

  /// 落账：题库记痕迹，答错的进错题本（它是真做错的一道题）。
  Future<void> _record() async {
    if (_recorded) return;
    _recorded = true;
    await widget.state.submitBankPractice(widget.items, _answers);
  }

  @override
  Widget build(BuildContext context) {
    final n = widget.items.length;
    final done = _verdicts.length;
    final correct = _verdicts.values.where((e) => e).length;

    return Scaffold(
      appBar: AppBar(
        title: Text(_submitted ? '结果 $correct / $done' : '练衍生题（$n 道）'),
        backgroundColor: const Color(0xFF1D4ED8),
        foregroundColor: Colors.white,
      ),
      body: Column(
        children: [
          if (!_submitted)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(14, 11, 14, 11),
              color: const Color(0xFFEFF6FF),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '这些都是你之前错过的题的同类题 —— 数字换了，做法一样。',
                    style: TextStyle(
                        fontSize: 12.5, color: Color(0xFF1E40AF), height: 1.5),
                  ),
                  if (widget.groupStem != null) ...[
                    const SizedBox(height: 5),
                    Text(
                      '原题：${widget.groupStem!}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 11.5, color: Color(0xFF64748B), height: 1.45),
                    ),
                  ],
                ],
              ),
            ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.only(bottom: 20, top: 6),
              children: [
                for (var i = 0; i < widget.items.length; i++)
                  QuestionCard(
                    q: widget.items[i].toQuestion(),
                    indexLabel: '第 ${i + 1} 题',
                    controller: _ctl[widget.items[i].id],
                    // 交卷后把作答显示出来：孩子要能看到"我当时写的是 285"，
                    // 才知道为什么被判错。交卷前传 null（不要动用户正在输入的内容）。
                    input: _submitted ? (_answers[widget.items[i].id] ?? '') : null,
                    correct: _submitted ? _verdicts[widget.items[i].id] : null,
                  ),
              ],
            ),
          ),
          if (_note != null)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              color: const Color(0xFFFFFBEB),
              child: Text(_note!,
                  style: const TextStyle(fontSize: 12, color: Color(0xFFB45309))),
            ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 8, 14, 12),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _submitted
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
