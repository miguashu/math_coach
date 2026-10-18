import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'package:math_coach/ai/quizgen.dart';

import '../state.dart';
import '../widgets/export_sheet.dart';
import '../widgets/question_card.dart';
import 'grade_page.dart';

/// 练习：选年级/知识点 → 出一套题 → 作答 → 批改讲解。
///
/// 批改前不显示任何答案 —— 讲解只在提交之后出现，
/// 答案讲得太早等于没练。
///
/// 布局（2026-10-16 重做，用户原话："这个布局不合理"）：
/// 旧版头部占了近半屏 —— 年级两行 chips + 难度 chips + 两个下拉 +
/// 大全宽"换一套题" + PDF 按钮，题卡被挤成一条，键盘一弹连题都看不见。
/// 新版把头部压到三行约 120px：题卷区拿回主体空间；
/// 作答点中题卡会自动滚进键盘上方的可见区；
/// 底部两个动作平权：手写作答走「提交批改」，纸上作答走「拍照判卷」。
class PracticePage extends StatefulWidget {
  final AppState state;
  const PracticePage({super.key, required this.state});

  @override
  State<PracticePage> createState() => _PracticePageState();
}

class _PracticePageState extends State<PracticePage> {
  int grade = 3;
  int count = 6;
  String? unit;
  QuizLevel level = QuizLevel.basic;
  ByteData? _font;
  bool _exporting = false;

  // 输入用 controller 缓存，避免弹键盘导致重建时丢字
  final Map<String, TextEditingController> _ctl = {};

  static const gradeNames = <int, String>{
    1: '一年级',
    2: '二年级',
    3: '三年级',
    4: '四年级',
    5: '五年级',
    6: '六年级',
  };

  TextEditingController _ctlOf(String id) =>
      _ctl.putIfAbsent(id, () => TextEditingController());

  List<String> get _units => KindCatalog.unitsOf(grade);

  @override
  void dispose() {
    for (final c in _ctl.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _newPaper() async {
    for (final c in _ctl.values) {
      c.clear();
    }
    await widget.state
        .newPractice(grade: grade, count: count, unit: unit, level: level);
  }

  /// 纸上作答（PDF 打印出来写）→ 拍照判卷。
  Future<void> _gradeByPhoto() async {
    FocusManager.instance.primaryFocus?.unfocus();
    await Navigator.of(context).push(MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => GradePage(state: widget.state),
    ));
    // 判卷结果已由 GradePage 写回 state（verdicts/submitted），这里刷新即可
    if (mounted) setState(() {});
  }

  /// 把当前这套题导出成 PDF 并唤起分享面板（微信/打印）。
  /// 竖式印题面（不印答案），家长拿到就能直接给孩子做。
  Future<void> _exportCurrent() async {
    final s = widget.state;
    if (s.current.isEmpty) return;
    _font ??= await loadChineseFont();
    if (_font == null) {
      _toast('中文字体加载失败，暂时无法导出');
      return;
    }
    setState(() => _exporting = true);
    try {
      final f = await s.exportPractice(
        title: '练习卷·${gradeNames[grade] ?? '$grade 年级'}',
        questions: s.current,
        fontData: _font,
      );
      if (!mounted) return;
      await showExportSheet(
        context,
        file: f,
        title: '${s.current.length} 道题的练习卷',
        count: s.current.length,
        state: s,
      );
    } catch (e) {
      _toast('导出失败：$e');
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.state;

    return Column(
      children: [
        // ── 紧凑操作区（三行，约 120px）──────────────────
        Container(
          width: double.infinity,
          color: const Color(0xFF2563EB),
          padding: const EdgeInsets.fromLTRB(12, 8, 8, 10),
          child: SafeArea(
            bottom: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // 第一行：标题 + 年级
                Row(
                  children: [
                    const Text(
                      '练习',
                      style: TextStyle(
                          color: Colors.white,
                          fontSize: 17,
                          fontWeight: FontWeight.w700),
                    ),
                    const Spacer(),
                    _HeaderSelect(
                      value: gradeNames[grade]!,
                      icon: Icons.school_outlined,
                      onTap: _pickGrade,
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                // 第二行：难度档 + 导出 PDF
                // 基础走本地题库（不联网也能出）；提高/奥数挑战由 AI 现场出应用题
                //
                // 2026-10-17 家长反馈"pdf 导出不太明显"：原来这里只是个
                // 小图标，藏在一排 chip 右边，第一次用根本发现不了。
                // 现在改成带文字的按钮，和难度 chip 平级。
                Row(
                  children: [
                    for (final lv in QuizLevel.values)
                      _LevelChip(
                        label: lv.label,
                        selected: level == lv,
                        onTap: () => setState(() => level = lv),
                      ),
                    const Spacer(),
                    if (s.current.isNotEmpty)
                      _ExportPdfButton(
                        busy: _exporting,
                        count: s.current.length,
                        onTap: _exportCurrent,
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                // 第三行：知识点 + 题数 + 换一套
                Row(
                  children: [
                    Expanded(
                      child: _HeaderSelect(
                        value: unit ?? '全部知识点',
                        icon: Icons.menu_book_outlined,
                        onTap: _pickUnit,
                      ),
                    ),
                    const SizedBox(width: 8),
                    _HeaderSelect(
                      value: '题数 $count',
                      icon: Icons.tag_outlined,
                      onTap: _pickCount,
                    ),
                    const SizedBox(width: 8),
                    _NewSetButton(busy: s.aiBusy, empty: s.current.isEmpty, onTap: _newPaper),
                  ],
                ),
                if (s.aiNote != null && s.aiNote!.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  _AiNote(s.aiNote!),
                ],
              ],
            ),
          ),
        ),

        // ── 题卷 ──────────────────────────────────────
        Expanded(
          child: s.current.isEmpty
              ? _EmptyHint(
                  icon: Icons.edit_outlined,
                  title: '还没有题目',
                  body: '上面选好年级和难度，点"换一套题"开始。\n'
                      '「基础」档在本地出题，不联网；'
                      '「提高」「奥数挑战」由 AI 现场出应用题，答案经本地验算后才上卷。\n'
                      '写在纸上的答案还能拍照判卷。',
                )
              : ListView(
                  padding: const EdgeInsets.only(bottom: 12, top: 8),
                  children: [
                    for (var i = 0; i < s.current.length; i++)
                      Builder(builder: (cardCtx) => QuestionCard(
                            q: s.current[i],
                            indexLabel: '第 ${i + 1} 题',
                            // 这里刻意给**明确的值**（含空串），不传 null：
                            // 输入框的内容以 state.inputs 为准。换一套题时
                            // inputs 被清空，正好把复用了同一个 controller 的
                            // 输入框一起清掉（题 id 一样就复用，不清会串上一套的答案）。
                            input: s.inputs[s.current[i].id]?.text ?? '',
                            // 拍照判卷只给认出的题写 verdict；
                            // 没认出的（无 verdict）标"未识别"，不判错
                            correct: s.submitted ? s.verdicts[s.current[i].id] : null,
                            unread: s.submitted &&
                                !s.verdicts.containsKey(s.current[i].id),
                            controller: _ctlOf(s.current[i].id),
                            onInputChanged: (v) => s.setInput(s.current[i].id, v),
                            // 键盘弹起会吃掉近半屏：把正在答的题滚进可见区
                            onAnswerFocused: () {
                              Future.delayed(
                                  const Duration(milliseconds: 350), () {
                                if (!cardCtx.mounted) return;
                                Scrollable.ensureVisible(
                                  cardCtx,
                                  duration: const Duration(milliseconds: 200),
                                  curve: Curves.easeOut,
                                  alignment: 0.08,
                                );
                              });
                            },
                          )),
                  ],
                ),
        ),

        // ── 底部操作条 ────────────────────────────────
        if (s.current.isNotEmpty)
          _BottomBar(
            state: s,
            onAgain: _newPaper,
            onGradePhoto: _gradeByPhoto,
          ),
      ],
    );
  }

  void _pickGrade() {
    _showSheet('选年级', [
      for (final g in gradeNames.keys)
        (label: gradeNames[g]!, onTap: () => setState(() {
              grade = g;
              unit = null;
            })),
    ]);
  }

  void _pickUnit() {
    _showSheet('选知识点（只练这个单元）', [
      (label: '全部知识点', onTap: () => setState(() => unit = null)),
      for (final u in _units) (label: u, onTap: () => setState(() => unit = u)),
    ]);
  }

  void _pickCount() {
    _showSheet('选题数', [
      for (final n in const [4, 6, 8, 10])
        (label: '$n 题', onTap: () => setState(() => count = n)),
    ]);
  }

  /// 年级/知识点/题数的选择器统一走底部弹层：
  /// 比内嵌下拉省一行高度，选项也多得看得清。
  void _showSheet(String title, List<({String label, VoidCallback onTap})> items) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 4, 18, 8),
              child: Text(title,
                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
            ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final it in items)
                    ListTile(
                      title: Text(it.label),
                      onTap: () {
                        Navigator.of(ctx).pop();
                        it.onTap();
                      },
                    ),
                ],
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}

/// 头部里的选择器（年级/知识点/题数）：白底半透明胶囊，点开底部弹层。
class _HeaderSelect extends StatelessWidget {
  final String value;
  final IconData icon;
  final VoidCallback onTap;
  const _HeaderSelect({required this.value, required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 32,
        padding: const EdgeInsets.symmetric(horizontal: 9),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.18),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: Colors.white.withOpacity(0.9)),
            const SizedBox(width: 5),
            Text(
              value,
              style: const TextStyle(color: Colors.white, fontSize: 12.5),
            ),
            Icon(Icons.arrow_drop_down, size: 17, color: Colors.white.withOpacity(0.9)),
          ],
        ),
      ),
    );
  }
}

/// 「导出 PDF」：带文字的按钮。
///
/// 原来只是右上角一个小图标（`_HeaderIcon`），家长第一次用完全找不到 ——
/// 2026-10-17 反馈"pdf 导出不太明显"。现在带文字、带题数，一眼看得见。
class _ExportPdfButton extends StatelessWidget {
  final bool busy;
  final int count;
  final VoidCallback onTap;
  const _ExportPdfButton({required this.busy, required this.count, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: busy ? null : onTap,
      child: Container(
        height: 28,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: busy ? Colors.white.withOpacity(0.5) : Colors.white,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (busy)
              const SizedBox(
                width: 13,
                height: 13,
                child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF1D4ED8)),
              )
            else
              const Icon(Icons.picture_as_pdf_outlined, size: 15, color: Color(0xFF1D4ED8)),
            const SizedBox(width: 5),
            Text(
              busy ? '导出中' : '导出 PDF · $count 题',
              style: const TextStyle(
                  color: Color(0xFF1D4ED8), fontSize: 12.5, fontWeight: FontWeight.w700),
            ),
          ],
        ),
      ),
    );
  }
}

/// 难度档 chip（基础/提高/奥数挑战）。
class _LevelChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _LevelChip({required this.label, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          height: 26,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: selected ? Colors.white : Colors.white.withOpacity(0.16),
            borderRadius: BorderRadius.circular(13),
          ),
          alignment: Alignment.center,
          child: Text(
            label,
            style: TextStyle(
              color: selected ? const Color(0xFF1D4ED8) : Colors.white,
              fontSize: 12,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w400,
            ),
          ),
        ),
      ),
    );
  }
}

/// 「换一套题」：工具栏里的实心小按钮，AI 出题时转圈。
class _NewSetButton extends StatelessWidget {
  final bool busy;
  final bool empty;
  final Future<void> Function() onTap;
  const _NewSetButton({required this.busy, required this.empty, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: busy ? null : onTap,
      child: Container(
        height: 32,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: busy ? Colors.white.withOpacity(0.5) : Colors.white,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (busy)
              const SizedBox(
                width: 13,
                height: 13,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: Color(0xFF1D4ED8)),
              )
            else
              const Icon(Icons.auto_awesome, size: 15, color: Color(0xFF1D4ED8)),
            const SizedBox(width: 5),
            Text(
              busy ? '出题中' : (empty ? '出一套题' : '换一套'),
              style: const TextStyle(
                  color: Color(0xFF1D4ED8),
                  fontSize: 13,
                  fontWeight: FontWeight.w700),
            ),
          ],
        ),
      ),
    );
  }
}

/// AI 状态说明（新题数 / 失败原因 / 未收录单元提示）。
class _AiNote extends StatelessWidget {
  final String text;
  const _AiNote(this.text);

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.18),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline, size: 13, color: Colors.white.withOpacity(0.9)),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              text,
              style: TextStyle(color: Colors.white, fontSize: 11.5, height: 1.4),
            ),
          ),
        ],
      ),
    );
  }
}

class _BottomBar extends StatelessWidget {
  final AppState state;
  final VoidCallback onAgain;
  final Future<void> Function() onGradePhoto;
  const _BottomBar({
    required this.state,
    required this.onAgain,
    required this.onGradePhoto,
  });

  @override
  Widget build(BuildContext context) {
    final total = state.current.length;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 10),
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
        child: state.submitted
            ? Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          state.unreadCount > 0
                              ? '答对 ${state.correctCount} / ${total - state.unreadCount}'
                                  '（${state.unreadCount} 题未识别）'
                              : '答对 ${state.correctCount} / $total',
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                            color: state.correctCount == total
                                ? const Color(0xFF16A34A)
                                : const Color(0xFF1D4ED8),
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          state.unreadCount > 0
                              ? '未识别的题照着照片手动补判，不会冤枉孩子'
                              : (state.correctCount == total
                                  ? '全对，这一轮可以过了'
                                  : '错的已经进错题本，明天会再见到'),
                          style: const TextStyle(
                              fontSize: 11.5, color: Color(0xFF64748B)),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  SizedBox(
                    height: 44,
                    child: FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFF2563EB),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10)),
                      ),
                      onPressed: onAgain,
                      child: const Text(
                        '再练一套',
                        style: TextStyle(
                            fontSize: 14.5, fontWeight: FontWeight.w700),
                      ),
                    ),
                  ),
                ],
              )
            : Row(
                children: [
                  // 纸上作答（打印出来的卷子）走拍照判卷
                  Expanded(
                    child: SizedBox(
                      height: 44,
                      child: OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: const Color(0xFF2563EB),
                          side: const BorderSide(color: Color(0xFF2563EB)),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10)),
                        ),
                        onPressed: onGradePhoto,
                        icon: const Icon(Icons.photo_camera_outlined, size: 18),
                        label: const Text(
                          '拍照判卷',
                          style: TextStyle(
                              fontSize: 14, fontWeight: FontWeight.w700),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    flex: 2,
                    child: SizedBox(
                      height: 44,
                      child: FilledButton.icon(
                        style: FilledButton.styleFrom(
                          backgroundColor: const Color(0xFF2563EB),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10)),
                        ),
                        onPressed: () async {
                          FocusManager.instance.primaryFocus?.unfocus();
                          await state.submit();
                        },
                        icon: const Icon(Icons.check, size: 18),
                        label: const Text(
                          '提交批改',
                          style: TextStyle(
                              fontSize: 14.5, fontWeight: FontWeight.w700),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}

class _EmptyHint extends StatelessWidget {
  final IconData icon;
  final String title;
  final String body;
  const _EmptyHint({required this.icon, required this.title, required this.body});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 46, color: const Color(0xFFCBD5E1)),
            const SizedBox(height: 12),
            Text(title,
                style: const TextStyle(
                    fontSize: 15, fontWeight: FontWeight.w600, color: Color(0xFF475569))),
            const SizedBox(height: 6),
            Text(
              body,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 12.5, color: Color(0xFF94A3B8), height: 1.6),
            ),
          ],
        ),
      ),
    );
  }
}
