/// 一道题的完整卡片：题干 + 配图/竖式 + 作答输入 + 批改后的讲解。
///
/// **配图一律从 spec 重放，不用 nucleus 塞进来的 SVG 字符串** ——
/// App 里没有引三方 SVG 包，更重要的是：屏幕上的 SVG 是按屏幕密度画的，
/// 而 EquationScene 是数学坐标，重放才能在任意尺寸下都清晰。
library;

import 'package:flutter/material.dart';

import 'package:math_coach/geometry/dsl/figure.dart';
import 'package:math_coach/geometry/solver/solver.dart';
import 'package:math_coach/quiz/question.dart';
import 'package:math_coach/store/repository.dart';
import 'package:math_coach/typeset/vertical.dart';

import '../render/figure_view.dart';
import '../render/vertical_view.dart';

class QuestionCard extends StatefulWidget {
  final QuizQuestion q;
  final String indexLabel;

  /// 这个输入框**应该显示**的内容。
  ///
  /// 语义（2026-10-17 明确）：
  /// - 传字符串（含空串）= "以这个值为准"，外部 controller 会被同步成它；
  /// - 传 null = "我不管这个框"，外部 controller 里的内容原样保留。
  ///
  /// 所以「换一套题要把输入一起清掉」的页面（练习页）必须显式传 `''`，
  /// 而不是省掉这个参数 —— 省掉等于说"别动用户写的东西"。
  final String? input;

  /// 提交前为 null，提交后为 true/false
  final bool? correct;

  final ValueChanged<String>? onInputChanged;

  /// 只读模式（错题本里查看）
  final bool readonly;

  /// 外部持有 controller 时用它的，否则内部自建（避免重建丢字）
  final TextEditingController? controller;

  /// 作答输入获得焦点时回调（父页用它把卡片滚进键盘上方的可见区）
  final VoidCallback? onAnswerFocused;

  /// 拍照判卷时没认出答案的题：不判对也不判错，输入框锁死，
  /// 状态标"未识别"。false = 普通题。
  final bool unread;

  const QuestionCard({
    super.key,
    required this.q,
    required this.indexLabel,
    this.input,
    this.correct,
    this.onInputChanged,
    this.readonly = false,
    this.controller,
    this.onAnswerFocused,
    this.unread = false,
  });

  /// 从 FigureSpec 重放出 scene（可能失败：参数不合法时给个提示而不是崩掉）。
  FigureScene? scene() {
    final spec = q.figureSpec;
    if (spec == null || spec.isEmpty) return null;
    try {
      return FigureSolver.solve(FigureSpec.fromJson(spec)).scene;
    } catch (_) {
      return null;
    }
  }

  @override
  State<QuestionCard> createState() => _QuestionCardState();
}

class _QuestionCardState extends State<QuestionCard> {
  TextEditingController? _own;

  TextEditingController get _ctl {
    if (widget.controller != null) {
      // 外部 controller 也要跟 widget.input 同步 —— 拍照判卷认出的答案是
      // 回到练习页后才写进 inputs 的，不同步的话输入框还显示着空的，
      // 家长看不到"到底认出了什么"，只有对错图标会显得莫名。
      // 正常键入时 onChanged 已经把同样的文本写进 state，两边相等即无操作。
      //
      // **只在 input 明确给了值时才同步**（2026-10-17 修）：
      // 以前 input == null 也当成空串去同步，于是"把外部 controller 里的作答
      // 清掉"。衍生题练习页就是只传 controller 不传 input 的，交卷后 setState
      // 一重建，孩子写的答案当场被抹掉（屏幕上看不到自己写了什么），
      // 紧接着落账读到的也是空串 —— 练了 3 道，题库里一条痕迹都没有。
      // input == null 的语义是"我不管这个框的内容"，不是"这个框应该是空的"。
      final want = widget.input;
      if (want != null && widget.controller!.text != want) {
        widget.controller!.text = want;
      }
      return widget.controller!;
    }
    if (_own == null) {
      _own = TextEditingController(text: widget.input ?? '');
      return _own!;
    }
    // 外部值变化（比如换了一套题）时同步一下，但不要打断正在输入的光标
    if (_own!.text != (widget.input ?? '')) {
      _own!.text = widget.input ?? '';
    }
    return _own!;
  }

  @override
  void dispose() {
    _own?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final q = widget.q;
    final correct = widget.correct;
    final readonly = widget.readonly;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: correct == null
              ? (widget.unread ? const Color(0xFFF59E0B) : const Color(0xFFE2E8F0))
              : (correct! ? const Color(0xFF16A34A) : const Color(0xFFDC2626)),
          width: correct == null && !widget.unread ? 1 : 1.6,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.04),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: const Color(0xFFEFF6FF),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    widget.indexLabel,
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF2563EB),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    q.kpPath,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 11.5, color: Color(0xFF64748B)),
                  ),
                ),
                if (q.isAi) ...[
                  const SizedBox(width: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: const Color(0xFF7C3AED).withOpacity(0.12),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: const Text(
                      'AI 新题',
                      style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          color: Color(0xFF7C3AED)),
                    ),
                  ),
                ],
                if (widget.unread)
                  const Icon(Icons.help_outline,
                      color: Color(0xFFF59E0B), size: 20)
                else if (correct != null)
                  Icon(
                    correct! ? Icons.check_circle : Icons.cancel,
                    color: correct! ? const Color(0xFF16A34A) : const Color(0xFFDC2626),
                    size: 20,
                  ),
              ],
            ),
            const SizedBox(height: 10),

            Text(
              q.stem,
              style: const TextStyle(fontSize: 16, height: 1.5, color: Color(0xFF0F172A)),
            ),

            if (_figureWidget(context) != null) ...[
              const SizedBox(height: 10),
              Center(child: _figureWidget(context)!),
            ],

            if (!readonly) ...[
              const SizedBox(height: 12),
              TextField(
                controller: _ctl,
                enabled: correct == null && !widget.unread,
                keyboardType: TextInputType.text,
                textInputAction: TextInputAction.next,
                onTap: widget.onAnswerFocused,
                onChanged: widget.onInputChanged,
                decoration: InputDecoration(
                  hintText: widget.unread ? '拍照判卷没认出这题' : '在这里作答',
                  isDense: true,
                  filled: true,
                  fillColor: const Color(0xFFF8FAFC),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(9),
                    borderSide: const BorderSide(color: Color(0xFFCBD5E1)),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(9),
                    borderSide: const BorderSide(color: Color(0xFFCBD5E1)),
                  ),
                ),
              ),
            ] else ...[
              const SizedBox(height: 10),
              _AnswerRow(label: '正确答案', text: q.answer.display),
            ],

            // 讲解只在批改之后出现 —— 先让他自己想，答案讲得太早等于没练
            if (correct != null) ...[
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(11),
                decoration: BoxDecoration(
                  color: correct! ? const Color(0xFFF0FDF4) : const Color(0xFFFEF2F2),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          correct! ? Icons.lightbulb_outline : Icons.error_outline,
                          size: 15,
                          color: correct! ? const Color(0xFF15803D) : const Color(0xFFB91C1C),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          correct! ? '思路回顾' : '这题再看一遍',
                          style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w700,
                            color: correct! ? const Color(0xFF15803D) : const Color(0xFFB91C1C),
                          ),
                        ),
                      ],
                    ),
                    if (!correct!) ...[
                      const SizedBox(height: 7),
                      _AnswerRow(label: '正确答案', text: q.answer.display),
                    ],
                    if (q.solutionSteps.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      for (var i = 0; i < q.solutionSteps.length; i++)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 5),
                          child: Text(
                            '${i + 1}. ${q.solutionSteps[i]}',
                            style: TextStyle(
                              fontSize: 13,
                              height: 1.55,
                              color: correct! ? const Color(0xFF166534) : const Color(0xFF7F1D1D),
                            ),
                          ),
                        ),
                    ],
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget? _figureWidget(BuildContext context) {
    final spec = widget.q.figureSpec;
    FigureScene? s;
    if (spec != null && spec.isNotEmpty) {
      try {
        s = FigureSolver.solve(FigureSpec.fromJson(spec)).scene;
      } catch (_) {
        s = null;
      }
    }
    if (s != null) {
      final w = (MediaQuery.of(context).size.width - 68).clamp(120.0, 340.0);
      return FigureView(scene: s, width: w);
    }
    // 竖式。作答前只给题面（不画进位/结果——否则题白出了），
    // 提交批改后或错题本回看时显示完整竖式。
    if (widget.q.verticalKind != null) {
      final revealed = widget.correct != null || widget.readonly;
      if (widget.q.verticalKind == 'div') {
        final d = VerticalReplay.longDivision(widget.q.verticalArgs, withAnswer: revealed);
        if (d != null) return LongDivisionView(d: d);
      }
      final layout = VerticalReplay.layout(widget.q.verticalKind!, widget.q.verticalArgs,
          withAnswer: revealed);
      if (layout != null) return VerticalView(layout: layout);
    }
    return null;
  }
}

class _AnswerRow extends StatelessWidget {
  final String label;
  final String text;
  const _AnswerRow({required this.label, required this.text});

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '$label：',
          style: const TextStyle(fontSize: 13, color: Color(0xFF64748B)),
        ),
        Expanded(
          child: Text(
            text,
            style: const TextStyle(
              fontSize: 14.5,
              fontWeight: FontWeight.w700,
              color: Color(0xFF0F172A),
            ),
          ),
        ),
      ],
    );
  }
}

/// 错题本里的记录也能用这个卡片（把 Record 转成 Question 显示）。
class RecordCard extends StatelessWidget {
  final QuizQuestion q;
  final ReviewRecord r;
  final String indexLabel;
  const RecordCard({
    super.key,
    required this.q,
    required this.r,
    required this.indexLabel,
  });

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        QuestionCard(q: q, indexLabel: indexLabel, readonly: true),
        Positioned(
          right: 14,
          top: 12,
          child: Row(
            children: [
              _Chip(
                text: '重要度 ${r.importance}',
                color: r.importance >= 4
                    ? const Color(0xFFDC2626)
                    : (r.importance > 0 ? const Color(0xFFF59E0B) : const Color(0xFF16A34A)),
              ),
              if (r.wrongCount > 0) ...[
                const SizedBox(width: 5),
                _Chip(text: '错 ${r.wrongCount} 次', color: const Color(0xFF64748B)),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _Chip extends StatelessWidget {
  final String text;
  final Color color;
  const _Chip({required this.text, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2.5),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        text,
        style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w600, color: color),
      ),
    );
  }
}
