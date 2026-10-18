/// 拍照判卷页：拍孩子的手写答案 → AI 认字 → 本地判分 → AI 批语 → 错题归档。
///
/// 分工（和整个 AI 层同一套哲学，见 lib/ai/grader.dart）：
/// - 模型只做两件事：把照片里的手写答案**认出来**、给答错的题**写批语**；
/// - **对不对永远由本地判分规则定**（QuizAnswer.check）——
///   模型认错字会被本地判分逮住，而且用户在确认前还能改识别结果；
/// - 认不出的题标「未识别」，不算错也不算对 —— 没看清就判错是冤枉孩子。
///
/// 用法：练习页底部「拍照判卷」。典型场景是家长把练习页导出的 PDF
/// 打印出来给孩子做，写完拍一张照片回来批。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import 'package:math_coach/ai/grader.dart';
import 'package:math_coach/quiz/question.dart';

import '../state.dart';
import '../widgets/image_prep.dart';

class GradePage extends StatefulWidget {
  final AppState state;
  const GradePage({super.key, required this.state});

  @override
  State<GradePage> createState() => _GradePageState();
}

class _GradePageState extends State<GradePage> {
  String? _photoPath;
  String? _busy; // 正在做什么（null = 空闲）
  String? _error;
  final List<_Item> _items = [];
  bool _confirmed = false;

  AppState get s => widget.state;

  @override
  void dispose() {
    for (final it in _items) {
      it.ctl.dispose();
    }
    super.dispose();
  }

  // ── 拍照 / 选图 ────────────────────────────────────

  Future<void> _take() async {
    final p = await s.takePhoto();
    if (p == null) {
      setState(() => _error = '没有拿到照片。如果这台设备没有相机应用，试试「从相册选」。');
      return;
    }
    _beginPhoto(p);
  }

  Future<void> _pick() async {
    final p = await s.pickImage();
    if (p == null) {
      setState(() => _error = '没有选到图片。');
      return;
    }
    _beginPhoto(p);
  }

  void _beginPhoto(String path) {
    setState(() {
      _photoPath = path;
      _error = null;
      _items.clear();
      _confirmed = false;
    });
    _read();
  }

  /// 缩图 → base64。原图动辄 4000px，直接传既慢又费 token。
  ///
  /// 2026-10-17：改走原生 JPEG（见 [encodeForModel]）——
  /// 原来的 PNG 编码对照片要大 7 倍（1935 KB vs 265 KB），
  /// 认卷等待时间里最大的一块就在这。
  Future<String?> _toBase64(File f) => encodeForModel(f);

  // ── 认卷 ───────────────────────────────────────────

  Future<void> _read() async {
    final path = _photoPath;
    if (path == null) return;
    if (s.current.isEmpty) {
      setState(() => _error = '当前没有要批改的卷子，请先回练习页出一套题。');
      return;
    }
    if (!s.aiConfig.visionReady) {
      setState(() => _error =
          '还没配置拍照识别模型。到「设置 → AI」填识别模型名（默认 deepseek-v4-flash 已能识图，也可换 qwen3-vl-plus）。');
      return;
    }
    setState(() {
      _busy = '正在认卷…';
      _error = null;
    });
    try {
      final b64 = await _toBase64(File(path));
      if (b64 == null) {
        setState(() {
          _busy = null;
          _error = '这张图读不了，换一张拍清楚点的试试。';
        });
        return;
      }
      final agent = GradeAgent(s.llm(), fallbackModel: s.aiConfig.visionFallbackModel);
      final res = await agent.readAnswers(imageBase64: b64, questions: s.current);
      await s.activityLog?.record('grade',
          detail: res.ok ? '认出 ${res.items.length} 条手写答案' : '认卷失败：${res.error}',
          latencyMs: res.latencyMs,
          model: res.model,
          tokens: res.totalTokens,
          ok: res.ok);
      if (!mounted) return;
      // 先收掉旧 controller 再清空（反了的话循环里已经没了）
      for (final old in _items) {
        old.ctl.dispose();
      }
      setState(() {
        _busy = null;
        _items.clear();
      });
      if (!res.ok) {
        setState(() => _error = res.error ?? '没能认出答案，可以重拍或手动输入');
        return;
      }
      final byNo = {for (final it in res.items) it.no: it};
      final items = <_Item>[];
      for (var i = 0; i < s.current.length; i++) {
        final q = s.current[i];
        final read = byNo[i + 1];
        final it = _Item(q: q);
        if (read != null && !read.unclear) {
          it.ctl.text = read.answer;
          it.uncertain = false;
          it.correct = q.answer.check(read.answer);
        } else {
          it.unread = true;
          it.uncertain = read?.unclear ?? true;
        }
        // 改认出的字 → 本地实时重判（判分规则就在本地，不麻烦模型）
        it.ctl.addListener(() {
          final t = it.ctl.text.trim();
          it.correct = t.isEmpty ? null : q.answer.check(t);
          if (t.isNotEmpty) it.unread = false;
          setState(() {});
        });
        items.add(it);
      }
      setState(() {
        _items.clear();
        _items.addAll(items);
      });
    } catch (e) {
      await s.activityLog?.record('grade', detail: '认卷失败：$e', ok: false);
      if (!mounted) return;
      setState(() {
        _busy = null;
        _error = '认卷失败：$e';
      });
    }
  }

  // ── 确认批改 ───────────────────────────────────────

  Future<void> _confirm() async {
    FocusManager.instance.primaryFocus?.unfocus();
    final wrong = <({int no, QuizQuestion q, String read})>[];
    for (var i = 0; i < _items.length; i++) {
      final it = _items[i];
      final t = it.ctl.text.trim();
      if (t.isNotEmpty && it.correct == false) {
        wrong.add((no: i + 1, q: it.q, read: t));
      }
    }
    setState(() => _busy = 'AI 正在写批语…');
    try {
      Map<int, String> comments = const {};
      if (wrong.isNotEmpty) {
        if (s.aiConfig.chatReady) {
          final agent = GradeAgent(s.llm(), fallbackModel: s.aiConfig.visionFallbackModel);
          comments = await agent.writeComments(wrong: wrong, grade: s.current.first.grade);
        }
      }
      for (final w in wrong) {
        final it = _items[w.no - 1];
        it.comment = comments[w.no];
      }
      // 判分结果落账：写回练习页的作答与 verdict，错题进错题本
      final results = <String, ({String read, bool correct})>{};
      for (final it in _items) {
        final t = it.ctl.text.trim();
        if (t.isNotEmpty && it.correct != null) {
          results[it.q.id] = (read: t, correct: it.correct!);
        }
      }
      await s.applyPhotoGrade(results);
      if (!mounted) return;
      setState(() {
        _busy = null;
        _confirmed = true;
      });
      // 衍生题：为判错的题造同类题进题库。
      // **故意不 await** —— 本地模板是毫秒级，模型那条路要十几秒，
      // 判卷结果该立刻可见，让家长对着转圈等出题是本末倒置。
      // 进度和结果由下面的状态条（监听 AppState）自己刷新。
      final wrongQs = <QuizQuestion>[
        for (final it in _items)
          if (it.correct == false) it.q,
      ];
      if (wrongQs.isNotEmpty) unawaited(s.deriveFromWrong(wrongQs));
      await s.activityLog?.record('grade',
          detail: '批改完成：对 ${results.values.where((r) => r.correct).length} / '
              '错 ${results.values.where((r) => !r.correct).length}',
          ok: true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = null;
        _error = '写批语失败（判卷结果已保存）：$e';
        _confirmed = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final hasPaper = s.current.isNotEmpty;
    return Scaffold(
      backgroundColor: const Color(0xFFF8FAFC),
      appBar: AppBar(
        title: const Text('拍照判卷'),
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: !hasPaper
          ? _Empty(
              icon: Icons.edit_outlined,
              title: '还没有要批改的卷子',
              body: '请先回「练习」页出一套题，打印或抄写后让孩子作答，\n'
                  '再来这里拍照判卷。',
              actionLabel: '回去出题',
              onAction: () => Navigator.of(context).pop(),
            )
          : Column(
              children: [
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(14, 10, 14, 20),
                    children: [
                      if (_photoPath == null) ...[
                        _ShootHint(onTake: _take, onPick: _pick),
                      ] else ...[
                        ClipRRect(
                          borderRadius: BorderRadius.circular(12),
                          child: Image.file(
                            File(_photoPath!),
                            height: 180,
                            width: double.infinity,
                            fit: BoxFit.cover,
                          ),
                        ),
                        const SizedBox(height: 10),
                        Row(
                          children: [
                            Expanded(
                              child: OutlinedButton.icon(
                                onPressed: _busy == null ? _take : null,
                                icon: const Icon(Icons.photo_camera_outlined, size: 17),
                                label: const Text('重拍'),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: OutlinedButton.icon(
                                onPressed: _busy == null ? _pick : null,
                                icon: const Icon(Icons.photo_library_outlined, size: 17),
                                label: const Text('换一张'),
                              ),
                            ),
                          ],
                        ),
                      ],
                      if (_busy != null) ...[
                        const SizedBox(height: 18),
                        _BusyRow(text: _busy!),
                      ],
                      if (_error != null) ...[
                        const SizedBox(height: 12),
                        _ErrorBox(text: _error!),
                      ],
                      if (_items.isNotEmpty) ...[
                        const SizedBox(height: 6),
                        _SummaryBar(items: _items, confirmed: _confirmed),
                        if (_confirmed) ...[
                          const SizedBox(height: 8),
                          _DeriveStatus(state: s),
                        ],
                        const SizedBox(height: 6),
                        for (var i = 0; i < _items.length; i++)
                          _GradeCard(
                            item: _items[i],
                            indexLabel: '第 ${i + 1} 题',
                            editable: !_confirmed,
                          ),
                      ],
                    ],
                  ),
                ),
                if (_items.isNotEmpty && !_confirmed)
                  SafeArea(
                    top: false,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(14, 8, 14, 10),
                      child: SizedBox(
                        width: double.infinity,
                        height: 46,
                        child: FilledButton.icon(
                          style: FilledButton.styleFrom(
                            backgroundColor: const Color(0xFF2563EB),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(10)),
                          ),
                          onPressed: _busy == null ? _confirm : null,
                          icon: const Icon(Icons.fact_check_outlined, size: 19),
                          label: Text(
                            _busy == null ? '确认批改' : '批改中…',
                            style: const TextStyle(
                                fontSize: 15, fontWeight: FontWeight.w700),
                          ),
                        ),
                      ),
                    ),
                  ),
                if (_confirmed)
                  SafeArea(
                    top: false,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(14, 8, 14, 10),
                      child: SizedBox(
                        width: double.infinity,
                        height: 46,
                        child: FilledButton(
                          style: FilledButton.styleFrom(
                            backgroundColor: const Color(0xFF16A34A),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(10)),
                          ),
                          onPressed: () => Navigator.of(context).pop(),
                          child: const Text(
                            '完成，回去看讲解',
                            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
    );
  }
}

/// 衍生题状态条：判完卷之后"还在出题 / 出好了 / 没出成"都在这里说清楚。
///
/// 用 ListenableBuilder 单独监听 AppState —— 衍生是后台任务，
/// 它在别的时刻完成，这一页得自己刷新，不能指望 setState。
class _DeriveStatus extends StatelessWidget {
  final AppState state;
  const _DeriveStatus({required this.state});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final busy = state.deriving;
        final note = state.deriveNote;
        if (!busy && (note == null || note.isEmpty)) {
          return const SizedBox.shrink();
        }
        final ok = !busy && note != null && note.contains('已进题库');
        final warn = !busy && !ok;
        final color = busy
            ? const Color(0xFF2563EB)
            : (ok ? const Color(0xFF15803D) : const Color(0xFFB45309));
        final bg = busy
            ? const Color(0xFFEFF6FF)
            : (ok ? const Color(0xFFF0FDF4) : const Color(0xFFFFFBEB));
        return Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (busy)
                const Padding(
                  padding: EdgeInsets.only(top: 1),
                  child: SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Color(0xFF2563EB)),
                  ),
                )
              else
                Icon(
                  ok
                      ? Icons.inventory_2_outlined
                      : (warn ? Icons.info_outline : Icons.check_circle_outline),
                  size: 15,
                  color: color,
                ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      note ?? '正在生成衍生题…',
                      style: TextStyle(fontSize: 12.5, height: 1.5, color: color),
                    ),
                    if (ok) ...[
                      const SizedBox(height: 3),
                      const Text(
                        '去「错题本 → 衍生题库」练这几道同类题',
                        style: TextStyle(fontSize: 11.5, color: Color(0xFF64748B)),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// 判卷中的一道题。
class _Item {
  final QuizQuestion q;
  final TextEditingController ctl = TextEditingController();

  /// 本地判分；null = 空答案未判
  bool? correct;

  /// 模型没认出答案（含"未作答"）
  bool unread = false;

  /// 识别不确定（字迹不清等）
  bool uncertain = false;

  /// AI 批语（答错时可能有）
  String? comment;

  _Item({required this.q});
}

class _ShootHint extends StatelessWidget {
  final Future<void> Function() onTake;
  final Future<void> Function() onPick;
  const _ShootHint({required this.onTake, required this.onPick});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(top: 6),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('拍一张孩子的手写答案',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          const Text(
            'AI 只负责认字，对错由本地判分规则定 —— 认错了您可以改，\n'
            '改完本地会重新判。认不出的题会标「未识别」，不会冤枉孩子。',
            style: TextStyle(fontSize: 12.5, color: Color(0xFF64748B), height: 1.6),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF2563EB),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10)),
                  ),
                  onPressed: onTake,
                  icon: const Icon(Icons.photo_camera_outlined, size: 18),
                  label: const Text('拍照'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFF2563EB),
                    side: const BorderSide(color: const Color(0xFF2563EB)),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10)),
                  ),
                  onPressed: onPick,
                  icon: const Icon(Icons.photo_library_outlined, size: 18),
                  label: const Text('从相册选'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _BusyRow extends StatelessWidget {
  final String text;
  const _BusyRow({required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xFFEFF6FF),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          const SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF2563EB)),
          ),
          const SizedBox(width: 10),
          Text(text, style: const TextStyle(fontSize: 13.5, color: Color(0xFF1E40AF))),
        ],
      ),
    );
  }
}

class _ErrorBox extends StatelessWidget {
  final String text;
  const _ErrorBox({required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(11),
      decoration: BoxDecoration(
        color: const Color(0xFFFEF2F2),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.error_outline, size: 16, color: Color(0xFFB91C1C)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(text,
                style: const TextStyle(fontSize: 12.5, color: Color(0xFFB91C1C), height: 1.5)),
          ),
        ],
      ),
    );
  }
}

/// 顶部小结：对 / 错 / 未识别 各几题。
class _SummaryBar extends StatelessWidget {
  final List<_Item> items;
  final bool confirmed;
  const _SummaryBar({required this.items, required this.confirmed});

  @override
  Widget build(BuildContext context) {
    var ok = 0, bad = 0, none = 0;
    for (final it in items) {
      if (it.correct == true) {
        ok++;
      } else if (it.correct == false) {
        bad++;
      } else {
        none++;
      }
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: confirmed ? const Color(0xFFF0FDF4) : const Color(0xFFEFF6FF),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Icon(
            confirmed ? Icons.fact_check : Icons.visibility,
            size: 16,
            color: confirmed ? const Color(0xFF15803D) : const Color(0xFF1E40AF),
          ),
          const SizedBox(width: 8),
          Text(
            confirmed ? '批改完成：' : '认出 ${items.length - none} 题：',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: confirmed ? const Color(0xFF15803D) : const Color(0xFF1E40AF),
            ),
          ),
          const SizedBox(width: 6),
          _Count(label: '对 $ok', color: const Color(0xFF16A34A)),
          const SizedBox(width: 8),
          _Count(label: '错 $bad', color: const Color(0xFFDC2626)),
          if (none > 0) ...[
            const SizedBox(width: 8),
            const _Count(label: '未识别', color: Color(0xFFF59E0B)),
          ],
        ],
      ),
    );
  }
}

class _Count extends StatelessWidget {
  final String label;
  final Color color;
  const _Count({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(label,
          style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: color)),
    );
  }
}

/// 一道题的判卷卡：题干摘要 + 可编辑的识别答案 + 本地实时判分状态。
class _GradeCard extends StatelessWidget {
  final _Item item;
  final String indexLabel;
  final bool editable;
  const _GradeCard({required this.item, required this.indexLabel, required this.editable});

  @override
  Widget build(BuildContext context) {
    final correct = item.correct;
    final border = correct == null
        ? const Color(0xFFE2E8F0)
        : (correct ? const Color(0xFF16A34A) : const Color(0xFFDC2626));

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: border, width: correct == null ? 1 : 1.5),
      ),
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
                  indexLabel,
                  style: const TextStyle(
                      fontSize: 12, fontWeight: FontWeight.w700, color: Color(0xFF2563EB)),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  item.q.stem,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12.5, color: Color(0xFF475569)),
                ),
              ),
              _StatusChip(item: item),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              const Text('认出的答案',
                  style: TextStyle(fontSize: 12, color: Color(0xFF64748B))),
              const SizedBox(width: 8),
              Expanded(
                child: SizedBox(
                  height: 40,
                  child: TextField(
                    controller: item.ctl,
                    enabled: editable,
                    style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                    decoration: InputDecoration(
                      hintText: item.unread ? '未识别（可手动输入）' : '在这里作答',
                      isDense: true,
                      filled: true,
                      fillColor: editable ? const Color(0xFFF8FAFC) : const Color(0xFFF1F5F9),
                      contentPadding:
                          const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: const BorderSide(color: Color(0xFFCBD5E1)),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
          if (item.uncertain && item.unread) ...[
            const SizedBox(height: 6),
            const Text('字迹不清或未作答 —— 没认出来的题不会判错，可手动补上',
                style: TextStyle(fontSize: 11.5, color: Color(0xFFB45309))),
          ],
          if (item.comment != null && item.comment!.isNotEmpty) ...[
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: const Color(0xFFFEF2F2),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Row(
                    children: [
                      Icon(Icons.edit_note, size: 14, color: Color(0xFFB91C1C)),
                      SizedBox(width: 5),
                      Text('AI 批语',
                          style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              color: Color(0xFFB91C1C))),
                    ],
                  ),
                  const SizedBox(height: 5),
                  Text(item.comment!,
                      style: const TextStyle(
                          fontSize: 13, height: 1.5, color: Color(0xFF7F1D1D))),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  final _Item item;
  const _StatusChip({required this.item});

  @override
  Widget build(BuildContext context) {
    final (text, color) = switch (item.correct) {
      true => ('对', const Color(0xFF16A34A)),
      false => ('错', const Color(0xFFDC2626)),
      null => item.unread
          ? ('未识别', const Color(0xFFF59E0B))
          : ('待判', const Color(0xFF64748B)),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2.5),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(text,
          style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: color)),
    );
  }
}

class _Empty extends StatelessWidget {
  final IconData icon;
  final String title;
  final String body;
  final String actionLabel;
  final VoidCallback onAction;
  const _Empty({
    required this.icon,
    required this.title,
    required this.body,
    required this.actionLabel,
    required this.onAction,
  });

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
            Text(body,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 12.5, color: Color(0xFF94A3B8), height: 1.6)),
            const SizedBox(height: 16),
            FilledButton(onPressed: onAction, child: Text(actionLabel)),
          ],
        ),
      ),
    );
  }
}
