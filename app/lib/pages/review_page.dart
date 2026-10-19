import 'package:flutter/material.dart';

import 'package:math_coach/review/fsrs.dart';
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
  bool _archived = false;
  int _correct = 0;

  /// 答对的题孩子/家长自评的档位。答错的题不在这里 —— 只可能是 again。
  final Map<String, Rating> _self = {};

  TextEditingController _ctlOf(String id) =>
      _ctl.putIfAbsent(id, () => TextEditingController());

  @override
  void dispose() {
    for (final c in _ctl.values) {
      c.dispose();
    }
    super.dispose();
  }

  /// 只判对错，**不落账**：先让孩子自评，再一起归档。
  ///
  /// 为什么不先落账再改：FSRS 的评分要进算法才算数，已经算过一次再补一次
  /// 会把 reps 记成两次、间隔也算歪。宁可多一次点击，也不能让"自评"变成
  /// 事后打折。没点确认就离开 = 这次没练，题目还在队列里，不会记错题。
  void _grade(List<ReviewRecord> rs) {
    FocusManager.instance.primaryFocus?.unfocus();
    var c = 0;
    for (final r in rs) {
      final q = AppState.questionFromRecord(r);
      if (q == null) continue;
      final input = _ctlOf(r.id).text.trim();
      final ok = input.isNotEmpty && q.answer.check(input);
      if (ok) {
        c++;
        _self.putIfAbsent(r.id, () => Rating.good);
      }
    }
    setState(() {
      _graded = true;
      _archived = false;
      _correct = c;
    });
  }

  Future<void> _archive(List<ReviewRecord> rs) async {
    final answers = <String, String>{for (final r in rs) r.id: _ctlOf(r.id).text};
    await widget.state.submitReview(rs, answers, selfRatings: _self);
    if (!mounted) return;
    setState(() => _archived = true);
  }

  void _nextRound() {
    for (final c in _ctl.values) {
      c.clear();
    }
    setState(() {
      _graded = false;
      _archived = false;
      _correct = 0;
      _self.clear();
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
                                    _archived
                                        ? (_correct == rs.length
                                            ? '已归档，间隔按你选的档往后推'
                                            : '答错的一会儿就回来，答对的按档往后排')
                                        : '给做对的题评个档（决定下次什么时候再见），再点确认归档',
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
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            QuestionCard(
                              q: q,
                              indexLabel: '复习 ${i + 1}',
                              controller: _ctlOf(r.id),
                              correct: verdict,
                            ),
                            if (_graded && verdict == true && !_archived)
                              _SelfRateRow(
                                record: r,
                                value: _self[r.id] ?? Rating.good,
                                onChanged: (v) =>
                                    setState(() => _self[r.id] = v),
                              ),
                            if (_graded && verdict == false && !_archived)
                              _AgainRow(record: r),
                          ],
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
                    backgroundColor: _graded
                        ? (_archived ? const Color(0xFF64748B) : const Color(0xFF16A34A))
                        : const Color(0xFF2563EB),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                  onPressed: () {
                    if (!_graded) {
                      _grade(rs);
                      return;
                    }
                    if (!_archived) {
                      _archive(rs);
                      return;
                    }
                    _nextRound();
                  },
                  child: Text(
                    !_graded
                        ? '提交批改'
                        : (_archived ? '下一轮' : '确认归档'),
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

/// 答对的题：三档自评。
///
/// 每一档下面都写着"选它 → 什么时候再见"（[FsrsScheduler.previewIntervals]）。
/// 不给这个数字，孩子点"有点难"和"很简单"就是盲选，
/// 四级评分里那两档跟没做一样 —— 反正他也不知道自己在选什么。
class _SelfRateRow extends StatelessWidget {
  final ReviewRecord record;
  final Rating value;
  final ValueChanged<Rating> onChanged;

  const _SelfRateRow({
    required this.record,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final preview =
        const FsrsScheduler().previewIntervals(record.fsrs, DateTime.now());
    return Container(
      margin: const EdgeInsets.fromLTRB(14, 0, 14, 12),
      padding: const EdgeInsets.fromLTRB(11, 9, 11, 10),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(11),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('做对了。这次感觉怎么样？',
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF475569))),
          const SizedBox(height: 8),
          Row(
            children: [
              for (var i = 0; i < selfReportRatings.length; i++) ...[
                if (i > 0) const SizedBox(width: 7),
                Expanded(
                  child: _chip(
                    selfReportRatings[i],
                    preview[selfReportRatings[i]],
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Widget _chip(Rating r, Duration? gap) {
    final on = r == value;
    return GestureDetector(
      onTap: () => onChanged(r),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 7),
        decoration: BoxDecoration(
          color: on ? const Color(0xFF2563EB) : Colors.white,
          borderRadius: BorderRadius.circular(9),
          border: Border.all(
            color: on ? const Color(0xFF2563EB) : const Color(0xFFCBD5E1),
          ),
        ),
        child: Column(
          children: [
            Text(r.label,
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: on ? Colors.white : const Color(0xFF334155))),
            const SizedBox(height: 2),
            Text(gap == null ? '' : _gapText(gap),
                style: TextStyle(
                    fontSize: 10.5,
                    color: on ? const Color(0xFFDBEAFE) : const Color(0xFF94A3B8))),
          ],
        ),
      ),
    );
  }
}

/// 答错的题：不给自评 —— 错就是错，没有"错得有点难"这一说。
class _AgainRow extends StatelessWidget {
  final ReviewRecord record;
  const _AgainRow({required this.record});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(14, 0, 14, 12),
      padding: const EdgeInsets.fromLTRB(11, 9, 11, 10),
      decoration: BoxDecoration(
        color: const Color(0xFFFEF2F2),
        borderRadius: BorderRadius.circular(11),
        border: Border.all(color: const Color(0xFFFECACA)),
      ),
      child: const Row(
        children: [
          Icon(Icons.refresh, size: 15, color: Color(0xFFDC2626)),
          SizedBox(width: 7),
          Expanded(
            child: Text('没做对 → 一会儿就再来一次（答错没有"有点难"这一说）',
                style: TextStyle(fontSize: 12, color: Color(0xFFB91C1C))),
          ),
        ],
      ),
    );
  }
}

String _gapText(Duration d) {
  if (d.inDays >= 1) return '${d.inDays} 天后再见';
  if (d.inHours >= 1) return '${d.inHours} 小时后再见';
  if (d.inMinutes >= 1) return '${d.inMinutes} 分钟后再见';
  return '马上再来';
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
