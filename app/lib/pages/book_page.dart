import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'package:math_coach/store/bank.dart';
import 'package:math_coach/store/repository.dart';

import '../state.dart';
import '../widgets/export_sheet.dart';
import '../widgets/question_card.dart';
import 'bank_practice_page.dart';
import 'challenge_page.dart';

/// 错题本：按重要度排序，不是按"错了几次"。
///
/// 重要度会衰减 —— 连续答对 3 次就归零并毕业。
/// 那种"错一次 +1、永远涨不回去"的算法会把清单变成一面耻辱墙，
/// 孩子看到的永远是"我又欠了多少"，而不是"我攻克了什么"。
///
/// 页内分两段：
///   - **错题本**：欠账清单，一条 = 一道做错过的原题（带 FSRS 复习调度）；
///   - **衍生题库**：补给站，一条 = 为某道错题造出来的同类练习题。
/// 两者分开是有意的：练习题混进错题本会把"要重点看"这类统计稀释掉。
class BookPage extends StatefulWidget {
  final AppState state;
  const BookPage({super.key, required this.state});

  @override
  State<BookPage> createState() => _BookPageState();
}

class _BookPageState extends State<BookPage> {
  String filter = 'all';

  /// 'wrong' = 错题本 / 'bank' = 衍生题库
  String mode = 'wrong';

  bool _busy = false;
  ByteData? _font;

  void _toast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating),
    );
  }

  /// 把错题本导出成可打印 PDF（错题本页自己的入口）。
  ///
  /// 和「设置 → 导出练习卷」是同一份数据、同一条路（连结果面板都是同一个组件），
  /// 区别只在于这里放了一个**看得见的按钮** —— 2026-10-17 家长反馈
  /// "pdf 导出不太明显"，而错题本恰恰是最想打印的地方。
  Future<void> _exportPaper(String title, List<ReviewRecord> records) async {
    if (records.isEmpty) return;
    _font ??= await loadChineseFont();
    if (_font == null) {
      _toast('中文字体加载失败，暂时无法导出');
      return;
    }
    setState(() => _busy = true);
    try {
      final f = await widget.state.exportPaper(
        title: title,
        records: records,
        fontData: _font,
      );
      if (!mounted) return;
      setState(() => _busy = false);
      await showExportSheet(
        context,
        file: f,
        title: title,
        count: records.length,
        state: widget.state,
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      _toast('导出失败：$e');
    }
  }

  Future<void> _confirmDelete(ReviewRecord r) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('从错题本移除？'),
        content: Text(
          r.stem.length > 40 ? '${r.stem.substring(0, 40)}…' : r.stem,
          style: const TextStyle(fontSize: 13.5, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFFDC2626)),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('移除'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await widget.state.forget(r.id);
    }
  }

  /// 拿最重要的前 3 题各出 2 道变体 —— 一组 6 道，正好一卷。
  void _challengeTop() {
    final list = widget.state.book.take(3).toList();
    if (list.isEmpty) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ChallengePage(state: widget.state, sources: list),
      ),
    );
  }

  Future<void> _replayTop() async {
    final list = widget.state.book.take(6).toList();
    if (list.isEmpty) return;
    widget.state.replay(list);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('已把最重要的 ${list.length} 题放进「练习」'),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  // ── 衍生题库 ────────────────────────────────────────────

  void _practiceBank(List<BankEntry> items, {String? groupStem}) {
    if (items.isEmpty) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => BankPracticePage(
          state: widget.state,
          items: items,
          groupStem: groupStem,
        ),
      ),
    );
  }

  Future<void> _confirmDropGroup(BankGroup g) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('移除这一组衍生题？'),
        content: Text(
          '这道错题衍生的 ${g.entries.length} 道练习题会一起删掉。\n'
          '错题本里的原题不受影响。',
          style: const TextStyle(fontSize: 13.5, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFFDC2626)),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('移除'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await widget.state.dropBankGroup(g.sourceQuestionId);
    }
  }

  /// 题库存了题干却拦不住"来源题被删了" —— 这里不做联动删除，
  /// 因为练习题本身还是好题，只是标一句提醒。
  Widget _bankBody(QuestionBank bank, Map<String, String> skips) {
    if (bank.count == 0) return _BankEmpty(skips: skips);
    final groups = bank.groups;
    return ListView(
      padding: const EdgeInsets.only(bottom: 20, top: 8),
      children: [
        for (final g in groups)
          _GroupCard(
            g: g,
            sourceKept: widget.state.repo.get(g.sourceQuestionId) != null,
            onPractice: () {
              // 优先练没过的；全过关了就整组重练一遍
              final left = g.entries.where((e) => !e.passed).toList();
              _practiceBank(left.isEmpty ? g.entries : left,
                  groupStem: g.sourceStem);
            },
            onPracticeOne: (e) => _practiceBank([e], groupStem: g.sourceStem),
            onDrop: () => _confirmDropGroup(g),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.state;
    final all = s.book;
    final now = DateTime.now();
    final st = s.stats(now);
    final bank = s.bank;

    return Column(
      children: [
        Container(
          width: double.infinity,
          color: const Color(0xFF2563EB),
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
          child: SafeArea(
            bottom: false,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _Segment(
                  mode: mode,
                  wrongCount: all.length,
                  bankCount: bank.count,
                  onChanged: (m) => setState(() => mode = m),
                ),
                const SizedBox(height: 12),
                if (mode == 'wrong') ..._wrongHeader(all, st) else ..._bankHeader(bank),
              ],
            ),
          ),
        ),
        Expanded(
          child: mode == 'wrong'
              ? _wrongBody(all, now)
              : _bankBody(bank, s.deriveSkips),
        ),
      ],
    );
  }

  // ── 错题本那一段 ────────────────────────────────────────

  List<Widget> _wrongHeader(
      List<ReviewRecord> all, ({int due, int attention, int mastered}) st) {
    return [
      Row(
        children: [
          _Stat(value: '${all.length}', label: '共收录'),
          const SizedBox(width: 10),
          _Stat(value: '${st.due}', label: '待复习'),
          const SizedBox(width: 10),
          _Stat(value: '${st.attention}', label: '要重点看'),
          const SizedBox(width: 10),
          _Stat(value: '${st.mastered}', label: '已拿下'),
        ],
      ),
      const SizedBox(height: 12),
      Row(
        children: [
          for (final f in const [
            ('all', '全部'),
            ('due', '待复习'),
            ('attention', '重点'),
          ])
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(
                label: Text(f.$2),
                selected: filter == f.$1,
                onSelected: (_) => setState(() => filter = f.$1),
                backgroundColor: Colors.white.withOpacity(0.16),
                selectedColor: Colors.white,
                labelStyle: TextStyle(
                  color: filter == f.$1 ? const Color(0xFF1D4ED8) : Colors.white,
                  fontSize: 12.5,
                  fontWeight: filter == f.$1 ? FontWeight.w700 : FontWeight.w400,
                ),
                visualDensity: VisualDensity.compact,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                showCheckmark: false,
              ),
            ),
          const Spacer(),
          if (all.isNotEmpty)
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextButton.icon(
                  onPressed: _replayTop,
                  icon: const Icon(Icons.replay, size: 15, color: Colors.white),
                  label: const Text('重做前 6 题',
                      style: TextStyle(color: Colors.white, fontSize: 12)),
                ),
                TextButton.icon(
                  onPressed: _challengeTop,
                  icon: const Icon(Icons.extension_outlined,
                      size: 15, color: Colors.white),
                  label: const Text('变体闯关',
                      style: TextStyle(color: Colors.white, fontSize: 12)),
                ),
              ],
            ),
        ],
      ),
      const SizedBox(height: 12),
      // 2026-10-17 家长反馈"pdf 导出不太明显"：原来导出只能从「设置」页进，
      // 埋在第四层。错题本是最可能想打印的地方（"把错题打出来让孩子重做"），
      // 所以这里放一个实心按钮，一眼看得见。
      if (all.isNotEmpty)
        SizedBox(
          width: double.infinity,
          height: 42,
          child: FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: Colors.white,
              foregroundColor: const Color(0xFF1D4ED8),
              disabledBackgroundColor: Colors.white.withOpacity(0.25),
              disabledForegroundColor: Colors.white70,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
            ),
            onPressed: _busy ? null : () => _exportPaper('错题练习卷', all),
            icon: const Icon(Icons.picture_as_pdf_outlined, size: 18),
            label: Text(
              _busy ? '正在生成…' : '导出 PDF · ${all.length} 道错题（可打印）',
              style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700),
            ),
          ),
        ),
      if (all.isNotEmpty) const SizedBox(height: 10),
    ];
  }

  Widget _wrongBody(List<ReviewRecord> all, DateTime now) {
    final shown = switch (filter) {
      'due' => all.where((r) => r.isDue(now)).toList(),
      'attention' => all.where((r) => r.needsAttention).toList(),
      _ => all,
    };
    if (shown.isEmpty) return _Empty(filter: filter);
    return ListView(
      padding: const EdgeInsets.only(bottom: 20, top: 6),
      children: [
        for (var i = 0; i < shown.length; i++)
          Builder(builder: (context) {
            final r = shown[i];
            final q = AppState.questionFromRecord(r);
            if (q == null) return const SizedBox.shrink();
            return Stack(
              children: [
                RecordCard(q: q, r: r, indexLabel: '${gradeName(r.grade)} · ${r.kpPath}'),
                Positioned(
                  right: 8,
                  bottom: 8,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // 变体闯关：同一类题换数字再练 —— 背下原题答案不算会
                      IconButton(
                        icon: const Icon(Icons.extension_outlined,
                            size: 18, color: Color(0xFF1D4ED8)),
                        tooltip: '变体闯关',
                        onPressed: () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => ChallengePage(
                              state: widget.state,
                              sources: [r],
                            ),
                          ),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.delete_outline,
                            size: 18, color: Color(0xFF94A3B8)),
                        onPressed: () => _confirmDelete(r),
                      ),
                    ],
                  ),
                ),
              ],
            );
          }),
      ],
    );
  }

  // ── 衍生题库那一段 ──────────────────────────────────────

  List<Widget> _bankHeader(QuestionBank bank) {
    final pending = bank.pending;
    return [
      Row(
        children: [
          _Stat(value: '${bank.count}', label: '衍生题'),
          const SizedBox(width: 10),
          _Stat(value: '${bank.pendingCount}', label: '未过关'),
          const SizedBox(width: 10),
          _Stat(value: '${bank.sourceCount}', label: '覆盖错题'),
        ],
      ),
      const SizedBox(height: 12),
      Row(
        children: [
          Expanded(
            child: FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: Colors.white,
                foregroundColor: const Color(0xFF1D4ED8),
                disabledBackgroundColor: Colors.white.withOpacity(0.25),
                disabledForegroundColor: Colors.white70,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
              ),
              onPressed: pending.isEmpty ? null : () => _practiceBank(pending),
              icon: const Icon(Icons.play_arrow_rounded, size: 18),
              label: Text(
                pending.isEmpty ? '全部过关了' : '练未过关的 ${pending.length} 道',
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
              ),
            ),
          ),
        ],
      ),
    ];
  }

  static String gradeName(int g) => switch (g) {
        1 => '一',
        2 => '二',
        3 => '三',
        4 => '四',
        5 => '五',
        6 => '六',
        _ => '$g',
      } + '年级';
}

/// 顶部两段切换：错题本 / 衍生题库。
class _Segment extends StatelessWidget {
  final String mode;
  final int wrongCount;
  final int bankCount;
  final ValueChanged<String> onChanged;
  const _Segment({
    required this.mode,
    required this.wrongCount,
    required this.bankCount,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    Widget seg(String key, String label, int n) {
      final on = mode == key;
      return Expanded(
        child: GestureDetector(
          onTap: () => onChanged(key),
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 3),
            padding: const EdgeInsets.symmetric(vertical: 7),
            decoration: BoxDecoration(
              color: on ? Colors.white : Colors.white.withOpacity(0.14),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    color: on ? const Color(0xFF1D4ED8) : Colors.white,
                    fontSize: 13.5,
                    fontWeight: on ? FontWeight.w700 : FontWeight.w500,
                  ),
                ),
                const SizedBox(width: 5),
                Text(
                  '$n',
                  style: TextStyle(
                    color: on ? const Color(0xFF1D4ED8) : Colors.white70,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Row(
        children: [
          seg('wrong', '错题本', wrongCount),
          seg('bank', '衍生题库', bankCount),
        ],
      ),
    );
  }
}

/// 一组衍生题：抬头是"它来自哪道错题"，下面是几道练习题。
class _GroupCard extends StatelessWidget {
  final BankGroup g;
  final bool sourceKept;
  final VoidCallback onPractice;
  final void Function(BankEntry) onPracticeOne;
  final VoidCallback onDrop;
  const _GroupCard({
    required this.g,
    required this.sourceKept,
    required this.onPractice,
    required this.onPracticeOne,
    required this.onDrop,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(14, 6, 14, 6),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFE2E8F0)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.03),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(13, 11, 13, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.link, size: 13, color: Color(0xFF94A3B8)),
                    const SizedBox(width: 5),
                    const Text('来自错题',
                        style: TextStyle(fontSize: 11.5, color: Color(0xFF94A3B8))),
                    if (!sourceKept) ...[
                      const SizedBox(width: 6),
                      const Text('（原题已移出错题本）',
                          style: TextStyle(fontSize: 11, color: Color(0xFFB45309))),
                    ],
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  g.sourceStem,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 12.5, height: 1.45, color: Color(0xFF475569)),
                ),
              ],
            ),
          ),
          const Divider(height: 1, color: Color(0xFFF1F5F9)),
          for (var i = 0; i < g.entries.length; i++)
            _BankRow(
              e: g.entries[i],
              no: i + 1,
              onTap: () => onPracticeOne(g.entries[i]),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 6, 6, 8),
            child: Row(
              children: [
                FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF2563EB),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8)),
                    visualDensity: VisualDensity.compact,
                  ),
                  onPressed: onPractice,
                  icon: const Icon(Icons.play_arrow_rounded, size: 17),
                  label: Text(
                    g.pending == 0 ? '再练一遍' : '练这 ${g.pending} 道',
                    style: const TextStyle(fontSize: 12.5),
                  ),
                ),
                const Spacer(),
                TextButton(
                  onPressed: onDrop,
                  child: const Text('移除这一组',
                      style: TextStyle(fontSize: 12, color: Color(0xFF94A3B8))),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 一条衍生题：题干 + 状态。点一下单独练这一道。
class _BankRow extends StatelessWidget {
  final BankEntry e;
  final int no;
  final VoidCallback onTap;
  const _BankRow({required this.e, required this.no, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final (text, color) = e.passed
        ? ('已过关', const Color(0xFF16A34A))
        : (e.untouched
            ? ('没练过', const Color(0xFF64748B))
            : ('练过 ${e.attempts} 次', const Color(0xFFF59E0B)));
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(13, 9, 13, 9),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 20,
              height: 20,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: const Color(0xFFF1F5F9),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text('$no',
                  style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF64748B))),
            ),
            const SizedBox(width: 9),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(e.stem,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 13, height: 1.45, color: Color(0xFF0F172A))),
                  if (e.isAi)
                    const Padding(
                      padding: EdgeInsets.only(top: 3),
                      child: Text('AI 出题 · 答案已本地验算',
                          style: TextStyle(fontSize: 10.5, color: Color(0xFF7C3AED))),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2.5),
              decoration: BoxDecoration(
                color: color.withOpacity(0.12),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(text,
                  style: TextStyle(
                      fontSize: 10.5, fontWeight: FontWeight.w700, color: color)),
            ),
          ],
        ),
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  final String value;
  final String label;
  const _Stat({required this.value, required this.label});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 8),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.16),
          borderRadius: BorderRadius.circular(9),
        ),
        child: Column(
          children: [
            Text(value,
                style: const TextStyle(
                    color: Colors.white, fontSize: 17, fontWeight: FontWeight.w700)),
            const SizedBox(height: 1),
            Text(label, style: const TextStyle(color: Color(0xFFBFDBFE), fontSize: 10.5)),
          ],
        ),
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  final String filter;
  const _Empty({required this.filter});

  @override
  Widget build(BuildContext context) {
    final text = filter == 'attention'
        ? '没有需要重点盯的题。\n重要度高的题都在这里'
        : (filter == 'due'
            ? '现在没有到期的题。\n到点了会自动出现在「复习」'
            : '错题本还是空的。\n去「练习」做几道题，错的会自动进来');
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 44),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              filter == 'all' ? Icons.inbox_outlined : Icons.check_circle_outline,
              size: 46,
              color: const Color(0xFFCBD5E1),
            ),
            const SizedBox(height: 12),
            Text(
              text,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 13, color: Color(0xFF94A3B8), height: 1.7),
            ),
          ],
        ),
      ),
    );
  }
}

/// 题库还是空的时候，把"为什么空"和"怎么才有"说清楚。
class _BankEmpty extends StatelessWidget {
  final Map<String, String> skips;
  const _BankEmpty({required this.skips});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.inventory_2_outlined, size: 46, color: Color(0xFFCBD5E1)),
            const SizedBox(height: 12),
            const Text('衍生题库还是空的',
                style: TextStyle(
                    fontSize: 15, fontWeight: FontWeight.w600, color: Color(0xFF475569))),
            const SizedBox(height: 8),
            const Text(
              '在「练习」页出一套题、打印出来给孩子做，\n'
              '再用底部的「拍照判卷」拍回来 —— 判错的题会自动\n'
              '衍生出几道同类练习题，就存在这里。',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12.5, color: Color(0xFF94A3B8), height: 1.7),
            ),
            if (skips.isNotEmpty) ...[
              const SizedBox(height: 14),
              Container(
                padding: const EdgeInsets.all(11),
                decoration: BoxDecoration(
                  color: const Color(0xFFFFFBEB),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  '上次判卷有 ${skips.length} 道错题没能衍生：\n${skips.values.first}',
                  style: const TextStyle(
                      fontSize: 12, color: Color(0xFFB45309), height: 1.6),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
