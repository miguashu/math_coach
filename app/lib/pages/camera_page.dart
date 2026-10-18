/// 拍照识题页：拍照/选图 → 模型 OCR 认题（**一次认多道**）→ 分步讲解 → 同类题。
///
/// 流程上每一环都可能失败（没填 key / 网络不通 / 模型乱答），
/// 所以每一步都有明确反馈，且**识别出来的题干必须让用户确认**再讲解 ——
/// 认错了也能改，而不是把错的题讲一遍。
///
/// 2026-10-17 家长反馈两点：
/// 1. "速度太慢" —— 图片改走原生 JPEG（原来编 PNG，对照片大 7 倍），见 `image_prep.dart`；
/// 2. "只能出现一道题，不太合理" —— 一张卷子照片上往往好几道题，
///    现在一次全认回来，一题一卡，各自讲、各自出同类题。
library;

import 'dart:io';

import 'package:flutter/material.dart';

import 'package:math_coach/ai/adopt.dart';
import 'package:math_coach/ai/ocr.dart';
import 'package:math_coach/ai/solver.dart';
import 'package:math_coach/ai/variants.dart';
import 'package:math_coach/review/fsrs.dart';

import '../state.dart';
import '../widgets/image_prep.dart';

class CameraPage extends StatefulWidget {
  final AppState state;
  const CameraPage({super.key, required this.state});

  @override
  State<CameraPage> createState() => _CameraPageState();
}

/// 一道认出来的题：题干可改、可单独讲、可单独出同类题。
///
/// 一道看不清不影响其他题 —— 这是"一次认多道"的意义。
class _StemBlock {
  final TextEditingController ctl;
  SolveResult? solve;
  String? busy; // '讲' / '题'
  String? error;
  List<GenVariant> variants = const [];
  final Map<int, TextEditingController> variantCtl = {};
  final Map<int, bool> verdicts = {};

  _StemBlock(String text) : ctl = TextEditingController(text: text);

  void dispose() {
    ctl.dispose();
    for (final c in variantCtl.values) {
      c.dispose();
    }
  }
}

class _CameraPageState extends State<CameraPage> {
  String? _photoPath;
  final List<_StemBlock> _blocks = [];
  String? _busy; // 整页的忙碌状态（认题中）
  String? _error;
  String? _ocrNotes;

  AppState get s => widget.state;

  @override
  void dispose() {
    for (final b in _blocks) {
      b.dispose();
    }
    super.dispose();
  }

  void _resetBlocks() {
    for (final b in _blocks) {
      b.dispose();
    }
    _blocks.clear();
  }

  Future<void> _take() async {
    final p = await s.takePhoto();
    if (p == null) {
      // 点完没反应是最糟的体验：要么用户取消了、要么这台设备没有相机 App
      setState(() => _error = '没有拿到照片。如果这台设备没有相机应用，试试「从相册选」。');
      return;
    }
    setState(() {
      _photoPath = p;
      _error = null;
      _ocrNotes = null;
      _resetBlocks();
    });
    await _ocrNow();
  }

  Future<void> _pick() async {
    final p = await s.pickImage();
    if (p == null) {
      setState(() => _error = '没有选到图片。');
      return;
    }
    setState(() {
      _photoPath = p;
      _error = null;
      _ocrNotes = null;
      _resetBlocks();
    });
    await _ocrNow();
  }

  /// 缩图 → base64。走原生 JPEG，比原来的 PNG 小 7 倍（实测 1935 KB → 265 KB）。
  Future<String?> _toBase64(File f) => encodeForModel(f);

  Future<void> _ocrNow() async {
    if (_photoPath == null) return;
    if (!s.aiConfig.visionReady) {
      setState(() => _error =
          '还没配置拍照识别模型。到「设置 → AI」填识别模型名（默认 deepseek-v4-flash 已能识图，也可换 qwen3-vl-plus）。');
      return;
    }
    setState(() {
      _busy = '正在认题…';
      _error = null;
    });
    try {
      final b64 = await _toBase64(File(_photoPath!));
      if (b64 == null) {
        setState(() {
          _busy = null;
          _error = '这张图读不了，换一张拍清楚点的试试。';
        });
        return;
      }
      final reader =
          PhotoReader(s.llm(), fallbackModel: s.aiConfig.visionFallbackModel);
      final r = await reader.read(b64);
      await s.activityLog?.record('ocr',
          detail: '识别完成：${r.count} 道题（${_brief(r.stem)}）',
          latencyMs: r.latencyMs,
          model: r.model,
          tokens: r.totalTokens);
      if (!mounted) return;
      setState(() {
        _resetBlocks();
        for (final stem in r.items) {
          _blocks.add(_StemBlock(stem));
        }
        _ocrNotes = r.notes;
        _busy = null;
      });
    } catch (e) {
      await s.activityLog?.record('ocr', detail: '识别失败：$e', ok: false);
      if (!mounted) return;
      setState(() {
        _busy = null;
        _error = '识别失败：$e';
      });
    }
  }

  Future<void> _explain(_StemBlock b) async {
    final stem = b.ctl.text.trim();
    if (stem.isEmpty) return;
    if (!s.aiConfig.chatReady) {
      setState(() => _error = '还没配置解题模型。到「设置 → AI」填 key（默认 DeepSeek）。');
      return;
    }
    setState(() {
      b.busy = '讲';
      b.error = null;
      b.solve = null;
    });
    try {
      final solver = KidSolver(s.llm());
      final r = await solver.solve(stem);
      await s.activityLog?.record('solve',
          detail: '讲解 ${r.steps.length} 步，答案 ${r.answer}${r.unit}'
              '${r.complete ? '' : '（步骤不完整）'}【${r.verifyState.label}】',
          ok: r.complete && r.verifyState != VerifyState.mismatch,
          latencyMs: r.latencyMs,
          model: r.model,
          tokens: r.totalTokens);
      if (!mounted) return;
      setState(() {
        b.solve = r;
        b.busy = null;
      });
    } catch (e) {
      await s.activityLog?.record('solve', detail: '讲解失败：$e', ok: false);
      if (!mounted) return;
      setState(() {
        b.busy = null;
        b.error = '讲解失败：$e';
      });
    }
  }

  Future<void> _genVariants(_StemBlock b) async {
    final stem = b.ctl.text.trim();
    if (stem.isEmpty) return;
    setState(() {
      b.busy = '题';
      b.error = null;
      b.variants = const [];
    });
    try {
      final agent = VariantAgent(s.llm());
      final list = await agent.generate(stem, n: 4);
      final localCount = list.where((e) => e.source == 'local').length;
      await s.activityLog?.record('variant',
          detail: '生成 ${list.length} 道同类题（本地 $localCount / 模型 ${list.length - localCount}）');
      if (!mounted) return;
      setState(() {
        b.variants = list;
        b.busy = null;
      });
    } catch (e) {
      await s.activityLog?.record('variant', detail: '出题失败：$e', ok: false);
      if (!mounted) return;
      setState(() {
        b.busy = null;
        b.error = '出题失败：$e';
      });
    }
  }

  String _brief(String s) => s.length <= 24 ? s : '${s.substring(0, 24)}…';

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.only(bottom: 40),
      children: [
        _header(),
        if (_error != null) _banner(_error!, const Color(0xFFDC2626)),
        if (_photoPath != null) _photoCard(),
        if (_blocks.isNotEmpty) _countCard(),
        for (var i = 0; i < _blocks.length; i++) _stemCard(i, _blocks[i]),
        if (_busy != null) _busyCard(_busy!),
        if (_photoPath == null) _hintCard(),
      ],
    );
  }

  Widget _header() => Container(
        width: double.infinity,
        color: const Color(0xFF0F766E),
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('拍照识题',
                style: TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            Text(
              '拍下不会的题（一张可以好几道）→ 认出来 → 一步一步讲给孩子听 → 出同类题练一练',
              style: TextStyle(color: Colors.white.withOpacity(0.85), fontSize: 12),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(
                        backgroundColor: Colors.white, foregroundColor: const Color(0xFF0F766E)),
                    onPressed: _take,
                    icon: const Icon(Icons.photo_camera_outlined, size: 18),
                    label: const Text('拍照', style: TextStyle(fontSize: 13.5)),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.white,
                      side: BorderSide(color: Colors.white.withOpacity(0.6)),
                    ),
                    onPressed: _pick,
                    icon: const Icon(Icons.photo_library_outlined, size: 18),
                    label: const Text('从相册选', style: TextStyle(fontSize: 13.5)),
                  ),
                ),
              ],
            ),
          ],
        ),
      );

  Widget _photoCard() => _Card(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Image.file(File(_photoPath!),
                  height: 190, width: double.infinity, fit: BoxFit.cover),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                TextButton.icon(
                  onPressed: _busy == null ? _ocrNow : null,
                  icon: const Icon(Icons.refresh, size: 16),
                  label: const Text('重新识别', style: TextStyle(fontSize: 12.5)),
                ),
                const SizedBox(width: 8),
                TextButton.icon(
                  onPressed: _take,
                  icon: const Icon(Icons.photo_camera_outlined, size: 16),
                  label: const Text('换一张', style: TextStyle(fontSize: 12.5)),
                ),
              ],
            ),
          ],
        ),
      );

  /// 认出几道题 + 模型的补充说明（哪几个字看不清、有没有图）。
  Widget _countCard() {
    final notes = _ocrNotes;
    return _Card(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.check_circle_outline, size: 16, color: Color(0xFF0F766E)),
          const SizedBox(width: 6),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('认出来 ${_blocks.length} 道题',
                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
                if (notes != null && notes.isNotEmpty) ...[
                  const SizedBox(height: 3),
                  Text(notes,
                      style: const TextStyle(fontSize: 11.5, color: Color(0xFF64748B), height: 1.45)),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _stemCard(int index, _StemBlock b) => _Card(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF0FDFA),
                    borderRadius: BorderRadius.circular(5),
                  ),
                  child: Text('第 ${index + 1} 题',
                      style: const TextStyle(
                          fontSize: 11, fontWeight: FontWeight.w700, color: Color(0xFF0F766E))),
                ),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text('认出来的题（可以改）',
                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
                ),
              ],
            ),
            const SizedBox(height: 8),
            TextField(
              controller: b.ctl,
              minLines: 2,
              maxLines: 5,
              style: const TextStyle(fontSize: 14),
              decoration: InputDecoration(
                isDense: true,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                contentPadding: const EdgeInsets.all(10),
              ),
            ),
            if (b.error != null) ...[
              const SizedBox(height: 6),
              Text(b.error!, style: const TextStyle(fontSize: 12, color: Color(0xFFDC2626))),
            ],
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: b.busy == null ? () => _explain(b) : null,
                    icon: const Icon(Icons.menu_book_outlined, size: 18),
                    label: Text(b.busy == '讲' ? '正在讲…' : '一步一步讲',
                        style: const TextStyle(fontSize: 13.5)),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: b.busy == null ? () => _genVariants(b) : null,
                    icon: const Icon(Icons.copy_all_outlined, size: 18),
                    label: Text(b.busy == '题' ? '正在出题…' : '出同类题',
                        style: const TextStyle(fontSize: 13.5)),
                  ),
                ),
              ],
            ),
            if (b.busy != null) ...[
              const SizedBox(height: 10),
              const Row(
                children: [
                  SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
                  SizedBox(width: 10),
                  Text('正在处理，马上就好…', style: TextStyle(fontSize: 12, color: Color(0xFF64748B))),
                ],
              ),
            ],
            if (b.solve != null) _solveBody(b.solve!),
            if (b.variants.isNotEmpty) _variantBody(b),
          ],
        ),
      );

  Widget _busyCard(String what) => _Card(
        child: Row(
          children: [
            const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
            const SizedBox(width: 12),
            Expanded(child: Text(what, style: const TextStyle(fontSize: 13))),
          ],
        ),
      );

  Widget _solveBody(SolveResult r) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 14),
          Row(
            children: [
              const Icon(Icons.lightbulb_outline, size: 17, color: Color(0xFFF59E0B)),
              const SizedBox(width: 6),
              const Expanded(
                child: Text('怎么做的',
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
              ),
              _verifiedChip(r.verifyState),
            ],
          ),
          if (!r.complete)
            Container(
              width: double.infinity,
              margin: const EdgeInsets.only(top: 10),
              padding: const EdgeInsets.all(9),
              decoration: BoxDecoration(
                color: const Color(0xFFFEF3C7),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: const Color(0xFFFDE68A)),
              ),
              child: const Text(
                '这份讲解不够细（没讲满两步或没说清答案），可以让它再讲一遍。'
                '答案以步骤为准，请家长一起看一眼。',
                style: TextStyle(fontSize: 12, color: Color(0xFF92400E), height: 1.5),
              ),
            ),
          const SizedBox(height: 10),
          for (var i = 0; i < r.steps.length; i++) _stepItem(i, r.steps[i]),
          if (r.answer.isNotEmpty) ...[
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
              decoration: BoxDecoration(
                color: const Color(0xFFECFDF5),
                borderRadius: BorderRadius.circular(9),
                border: Border.all(color: const Color(0xFFBBF7D0)),
              ),
              child: Text('答案：${r.answer}${r.unit}',
                  style: const TextStyle(
                      fontSize: 15, fontWeight: FontWeight.w700, color: Color(0xFF15803D))),
            ),
          ],
          const SizedBox(height: 6),
          Text('模型 ${r.model} · ${r.latencyMs} ms · ${r.totalTokens} tokens',
              style: const TextStyle(fontSize: 10.5, color: Color(0xFF94A3B8))),
        ],
      );

  /// 三态：**没有验算过就不能显示"已验算"** —— 这是在守"不冒充正确"这条线。
  Widget _verifiedChip(VerifyState st) {
    final (bg, border, fg, text) = switch (st) {
      VerifyState.exact => (
          const Color(0xFFECFDF5),
          const Color(0xFFBBF7D0),
          const Color(0xFF15803D),
          '已本地验算 ✓'
        ),
      VerifyState.unverifiable => (
          const Color(0xFFF1F5F9),
          const Color(0xFFE2E8F0),
          const Color(0xFF475569),
          '未能本地验算'
        ),
      VerifyState.mismatch => (
          const Color(0xFFFEF2F2),
          const Color(0xFFFECACA),
          const Color(0xFFB91C1C),
          '验算不一致 ⚠'
        ),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: border),
      ),
      child: Text(text,
          style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w600, color: fg)),
    );
  }

  Widget _stepItem(int i, SolveStep st) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 22,
              height: 22,
              alignment: Alignment.center,
              decoration: const BoxDecoration(
                  color: Color(0xFF0F766E), shape: BoxShape.circle),
              child: Text('${i + 1}',
                  style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w700)),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(st.title,
                      style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                  if (st.detail.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(st.detail,
                        style: const TextStyle(fontSize: 13, color: Color(0xFF334155), height: 1.45)),
                  ],
                  if (st.math.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                          color: const Color(0xFFF1F5F9), borderRadius: BorderRadius.circular(6)),
                      child: Text(st.math,
                          style: const TextStyle(
                              fontSize: 13, fontFamily: 'monospace', color: Color(0xFF1E293B))),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      );

  /// 同类题**要能真的做**：每道配输入框，提交后本地判分，
  /// 答错自动进错题本（也就进了复习队列）—— 不然只是陈列，练不了。
  Widget _variantBody(_StemBlock b) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 14),
          const Row(
            children: [
              Icon(Icons.copy_all_outlined, size: 17, color: Color(0xFF2563EB)),
              SizedBox(width: 6),
              Expanded(
                child: Text('同类题（做完提交，错的会进错题本）',
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
              ),
            ],
          ),
          const SizedBox(height: 8),
          for (var i = 0; i < b.variants.length; i++) _variantItem(b, i, b.variants[i]),
        ],
      );

  Widget _variantItem(_StemBlock b, int i, GenVariant v) {
    final ctl = b.variantCtl.putIfAbsent(i, () => TextEditingController());
    final verdict = b.verdicts[i];
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: v.source == 'local' ? const Color(0xFFECFDF5) : const Color(0xFFEFF6FF),
                  borderRadius: BorderRadius.circular(5),
                ),
                child: Text(v.source == 'local' ? '本地' : 'AI',
                    style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                        color: v.source == 'local'
                            ? const Color(0xFF15803D)
                            : const Color(0xFF1D4ED8))),
              ),
              const SizedBox(width: 8),
              Expanded(child: Text(v.stem, style: const TextStyle(fontSize: 13.5, height: 1.4))),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: 38,
                  child: TextField(
                    controller: ctl,
                    enabled: verdict == null,
                    keyboardType: TextInputType.number,
                    style: const TextStyle(fontSize: 14),
                    decoration: InputDecoration(
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                      hintText: '答案${v.unit.isEmpty ? '' : '（${v.unit}）'}',
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                height: 38,
                child: verdict == null
                    ? FilledButton(
                        onPressed: () => _submitVariant(b, i, v),
                        child: const Text('提交', style: TextStyle(fontSize: 13)),
                      )
                    : Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                        decoration: BoxDecoration(
                          color: verdict ? const Color(0xFFF0FDF4) : const Color(0xFFFEF2F2),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: verdict ? const Color(0xFFBBF7D0) : const Color(0xFFFECACA),
                          ),
                        ),
                        child: Text(verdict ? '对了' : '错了 ${v.answer}${v.unit}',
                            style: TextStyle(
                                fontSize: 12.5,
                                fontWeight: FontWeight.w600,
                                color: verdict
                                    ? const Color(0xFF15803D)
                                    : const Color(0xFFB91C1C))),
                      ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _submitVariant(_StemBlock b, int i, GenVariant v) async {
    final input = (b.variantCtl[i]?.text ?? '').trim();
    if (input.isEmpty) return;
    final q = AdoptedQuestion.fromGen(v);
    final correct = q.answer.check(input);
    setState(() => b.verdicts[i] = correct);
    // 归档：错的进错题本，也就进了复习队列 —— 这才是"练"
    await s.repo.recordAttempt(
      q,
      correct: correct,
      rating: correct ? Rating.good : Rating.again,
    );
    await s.activityLog?.record('practice',
        detail: '同类题作答：${correct ? '答对' : '答错'}（${v.stem}）', ok: true);
    s.refresh();
  }

  Widget _hintCard() => _Card(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('用之前', style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            _hint('1. 默认已预置一套可用的模型（DeepSeek V4，文字与识图都能跑），'
                '想用自己的额度就到「设置 → AI」改 key'),
            _hint('2. 拍照后先看看认出来的题目对不对，不对可以直接改'),
            _hint('3. 一张照片上有多道题会一起认出来，一题一卡，讲哪题点哪题'),
            _hint('4. 讲解是一步一步来的，每一步说清"做什么、为什么"'),
            _hint('5. 简单题的同类题在本地生成（答案必对），复杂题才交给模型，且都要过验算'),
          ],
        ),
      );

  Widget _hint(String t) => Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Text(t, style: const TextStyle(fontSize: 12.5, color: Color(0xFF475569), height: 1.5)),
      );

  Widget _banner(String msg, Color c) => Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 0),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: c.withOpacity(0.08),
            borderRadius: BorderRadius.circular(9),
            border: Border.all(color: c.withOpacity(0.4),
            ),
          ),
          child: Text(msg, style: TextStyle(fontSize: 12.5, color: c)),
        ),
      );
}

class _Card extends StatelessWidget {
  final Widget child;
  const _Card({required this.child});

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.fromLTRB(14, 12, 14, 0),
        padding: const EdgeInsets.all(13),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(13),
          border: Border.all(color: const Color(0xFFE2E8F0)),
          boxShadow: [
            BoxShadow(color: Colors.black.withOpacity(0.04), blurRadius: 8, offset: const Offset(0, 2)),
          ],
        ),
        child: child,
      );
}
