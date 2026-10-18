import 'package:flutter/material.dart';

import 'package:math_coach/store/repository.dart';

import '../state.dart';
import '../widgets/question_card.dart';

/// 复习：按 FSRS 到期时间给题，答错马上回到队首。
///
/// 这里刻意不是"再考一遍错题本前 N 条" —— 复习解决的是"什么时候该再见一面"，
/// 清单优先度（重要度）解决的是"排多前"，两件事分开看。
class ReviewPage extends StatefulWidget {
  final AppState state;
  const ReviewPage({super.key, required this.state});

  @override
  State<ReviewPage> createState() => _ReviewPageState();
}

class _ReviewPageState extends State<ReviewPage> {
  final Map<String, TextEditingController> _ctl = {};
  bool _graded = false;
  int _correct = 0;

  TextEditingController _ctlOf(String id) =>
      _ctl.putIfAbsent(id, () => TextEditingController());

  @override
  void dispose() {
    for (final c in _ctl.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _submit(List<ReviewRecord> rs) async {
    FocusManager.instance.primaryFocus?.unfocus();
    final answers = <String, String>{for (final r in rs) r.id: _ctlOf(r.id).text};
    var c = 0;
    for (final r in rs) {
      final q = AppState.questionFromRecord(r);
      if (q == null) continue;
      if (answers[r.id]!.trim().isNotEmpty && q.answer.check(answers[r.id]!)) c++;
    }
    await widget.state.submitReview(rs, answers);
    if (!mounted) return;
    setState(() {
      _graded = true;
      _correct = c;
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.state;
    final rs = s.dueQueue();

    return Column(
      children: [
        _Header(count: rs.length),
        Expanded(
          child: rs.isEmpty
              ? _Done()
              : ListView(
                  padding: const EdgeInsets.only(bottom: 100, top: 6),
                  children: [
                    if (_graded)
                      Container(
                        margin: const EdgeInsets.fromLTRB(14, 6, 14, 10),
                        padding: const EdgeInsets.all(13),
                        decoration: BoxDecoration(
                          color: _correct == rs.length
                              ? const Color(0xFFF0FDF4)
                              : const Color(0xFFEFF6FF),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: _correct == rs.length
                                ? const Color(0xFF86EFAC)
                                : const Color(0xFFBFDBFE),
                          ),
                        ),
                        child: Row(
                          children: [
                            Icon(
                              _correct == rs.length ? Icons.celebration : Icons.trending_up,
                              color: _correct == rs.length
                                  ? const Color(0xFF16A34A)
                                  : const Color(0xFF2563EB),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    '答对 $_correct / ${rs.length}',
                                    style: const TextStyle(
                                        fontSize: 14.5, fontWeight: FontWeight.w700),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    _correct == rs.length
                                        ? '全对，间隔会自动往后推'
                                        : '答错的明天再来一次，直到连续答对',
                                    style: const TextStyle(
                                        fontSize: 11.5, color: Color(0xFF64748B)),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    for (var i = 0; i < rs.length; i++)
                      Builder(builder: (context) {
                        final r = rs[i];
                        final q = AppState.questionFromRecord(r);
                        if (q == null) return const SizedBox.shrink();
                        bool? verdict;
                        if (_graded) {
                          final input = _ctlOf(r.id).text.trim();
                          verdict = input.isNotEmpty && q.answer.check(input);
                        }
                        return QuestionCard(
                          q: q,
                          indexLabel: '复习 ${i + 1}',
                          controller: _ctlOf(r.id),
                          correct: verdict,
                        );
                      }),
                  ],
                ),
        ),
        if (rs.isNotEmpty)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
            decoration: BoxDecoration(
              color: Colors.white,
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.07),
                  blurRadius: 12,
                  offset: const Offset(0, -3),
                ),
              ],
            ),
            child: SafeArea(
              top: false,
              child: SizedBox(
                height: 44,
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor:
                        _graded ? const Color(0xFF64748B) : const Color(0xFF2563EB),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                  onPressed: () {
                    if (!_graded) {
                      _submit(rs);
                      return;
                    }
                    // 下一轮：清掉输入回到未批改状态
                    for (final c in _ctl.values) {
                      c.clear();
                    }
                    setState(() {
                      _graded = false;
                      _correct = 0;
                    });
                  },
                  child: Text(
                    _graded ? '下一轮' : '提交批改',
                    style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _Header extends StatelessWidget {
  final int count;
  const _Header({required this.count});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      color: const Color(0xFF2563EB),
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
      child: SafeArea(
        bottom: false,
        child: Row(
          children: [
            const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('复习',
                    style: TextStyle(
                        color: Colors.white, fontSize: 19, fontWeight: FontWeight.w700)),
                SizedBox(height: 3),
                Text('到期的题会在这里出现',
                    style: TextStyle(color: Color(0xFFBFDBFE), fontSize: 11.5)),
              ],
            ),
            const Spacer(),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.18),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                '$count 道待复习',
                style: const TextStyle(
                    color: Colors.white, fontSize: 12.5, fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Done extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 44),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.check_circle_outline, size: 48, color: Color(0xFF86EFAC)),
            const SizedBox(height: 12),
            const Text('暂时没有要复习的',
                style: TextStyle(
                    fontSize: 15, fontWeight: FontWeight.w600, color: Color(0xFF475569))),
            const SizedBox(height: 6),
            const Text(
              '不是"没有错题"，而是都还没到该再见的时刻。\n等间隔到了会自动回来。',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12.5, color: Color(0xFF94A3B8), height: 1.6),
            ),
          ],
        ),
      ),
    );
  }
}
