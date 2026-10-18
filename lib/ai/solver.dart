/// 解题讲解 Agent：把一道题讲给小学生听。
///
/// 流程（这是「Agent」而不是一次调用 · 每一步都可能打回重做）：
///   1. 首次调用 — 模型按「第一步干什么、第二步干什么」的结构输出 JSON；
///   2. 完整性检查 — 步骤少于 2 步、或没说答案、或答案读不出数字
///                 → 打回重做（用户明确要求"步骤必须全面"）；
///   3. 本地验算 — 模型给的 equation 用 Rational 精确重算，
///                 与它报的答案对不上 → 打回重做；
///   4. 仍不符   → verifyState = mismatch，界面亮红牌。
///
/// **验算状态三态，不许二态**：
///   exact=本地复算一致 / unverifiable=没法验算 / mismatch=不一致。
/// 曾经把"没给验算式但有答案"当成通过 —— 等于没验算却亮绿勾，那是冒充正确，改掉了。
library;

import 'dart:convert';

import '../core/rational.dart';
import 'expr.dart';
import 'llm.dart';

class SolveStep {
  final String title;
  final String detail;
  final String math;
  const SolveStep({required this.title, required this.detail, this.math = ''});
}

/// 验算状态（三态）。
enum VerifyState {
  /// 本地精确复算与模型答案一致
  exact('已本地验算'),
  /// 题目写不成一条算式，本地算不了（应用题常见）—— 不冒充正确
  unverifiable('未能本地验算'),
  /// 算出来的和模型报的不一致
  mismatch('验算不一致');

  const VerifyState(this.label);
  final String label;
}

class SolveResult {
  final List<SolveStep> steps;
  final String answer;
  final String unit;
  final String? equation;
  final VerifyState verifyState;

  /// 步骤是否讲完整（至少 2 步且最后落到了答案）。
  final bool complete;
  final int latencyMs;
  final int totalTokens;
  final String model;
  final int attempts;
  const SolveResult({
    required this.steps,
    required this.answer,
    required this.unit,
    required this.verifyState,
    required this.complete,
    required this.latencyMs,
    required this.totalTokens,
    required this.model,
    required this.attempts,
    this.equation,
  });
}

class _Attempt {
  final List<SolveStep> steps;
  final String answer;
  final String unit;
  final String? equation;
  final VerifyState verifyState;
  final bool complete;
  final bool parseFailed;
  final String? rawJson;
  final int latencyMs;
  final int totalTokens;
  final String model;
  _Attempt(this.steps, this.answer, this.unit, this.equation, this.verifyState,
      this.complete, this.parseFailed, this.rawJson, this.latencyMs, this.totalTokens,
      this.model);
}

class KidSolver {
  final LlmPort client;

  /// 少于这个步数就认为"讲得不够细"，必须打回重做。
  static const int minSteps = 2;

  KidSolver(this.client);

  static const _system = '''
你是一位优秀的小学数学老师，讲解对象是 6~12 岁的小学生。

硬性要求：
1. 必须分步骤讲：第一步干什么、第二步干什么……每一步写清「做什么、为什么这么做、算式是什么」。
   至少要有 2 步；一步到位的讲解不合格。
2. 语言简单明了，像老师嘴边的话，不用孩子没学过的术语。
3. 每一步尽量不超过两句话。能配一句生活化的比喻就配。
4. 最后一步必须明确说出最终答案和单位。

只输出 JSON，不要输出任何其他文字，格式：
{
  "steps": [
    {"title": "第一步：…", "detail": "…", "math": "算式或空字符串"},
    …
  ],
  "answer": "最终答案（数字）",
  "unit": "单位，如 米/平方厘米/个，没有就空字符串",
  "equation": "从原题条件直接到最终答案的一条完整四则算式，用于验算。"
              "只写算式本身，不要写等号和答案（写 "12-3-4"，不要写 "12-3-4=5"）；确实写不成一条算式就填空字符串"
}''';

  Future<SolveResult> solve(String stem, {int grade = 3}) async {
    final messages = <LlmMessage>[
      const LlmMessage('system', _system),
      LlmMessage('user', '（这是 $grade 年级学生的题）\n$stem'),
    ];

    var latency = 0;
    var tokens = 0;
    var attempts = 1;
    var attempt = await _run(messages);
    latency += attempt.latencyMs;
    tokens += attempt.totalTokens;

    if (!attempt.complete || attempt.verifyState == VerifyState.mismatch) {
      final why = <String>[];
      if (!attempt.complete) {
        why.add(attempt.steps.isEmpty
            ? '你没有输出可解析的步骤'
            : '你只讲了 ${attempt.steps.length} 步，至少要 $minSteps 步'
                '（第一步干什么、第二步干什么），并且最后一步要说清答案和单位');
      }
      if (attempt.verifyState == VerifyState.mismatch) {
        why.add(attempt.parseFailed
            ? 'equation="${attempt.equation}" 不是可计算的纯数字四则算式，'
                '请写成只含数字和 + - * / ( ) 的完整算式'
            : '你报的答案 "${attempt.answer}" 与 equation="${attempt.equation}" '
                '本地精确计算的结果不一致');
      }
      messages.add(LlmMessage('assistant', attempt.rawJson ?? ''));
      messages.add(LlmMessage(
          'user', '${why.join('；')}。请重新检查每一步，按同样的 JSON 格式重新输出全部内容。'));
      final retry = await _run(messages);
      latency += retry.latencyMs;
      tokens += retry.totalTokens;
      attempts = 2;
      attempt = retry;
    }

    return SolveResult(
      steps: attempt.steps,
      answer: attempt.answer,
      unit: attempt.unit,
      equation: attempt.equation,
      verifyState: attempt.verifyState,
      complete: attempt.complete,
      latencyMs: latency,
      totalTokens: tokens,
      model: attempt.model,
      attempts: attempts,
    );
  }

  Future<_Attempt> _run(List<LlmMessage> messages) async {
    // 3000 是上限不是预扣（用不到不花钱）。给宽裕是因为 deepseek-v4-flash
    // 这类推理模型会先花几百 token 想思路，再输出 JSON 正文。
    final reply = await client.chat(messages, temperature: 0.2, maxTokens: 3000);
    final (steps, answer, unit, equation, raw) = _parse(reply.text);
    final (state, parseFailed) = _verify(equation, answer);
    final complete = _isComplete(steps, answer);
    return _Attempt(steps, answer, unit, equation, state, complete, parseFailed, raw,
        reply.latencyMs, reply.totalTokens, reply.model);
  }

  /// 「讲完整」= 至少两步 + 有答案 + 答案是能读出来的数字。
  bool _isComplete(List<SolveStep> steps, String answer) {
    if (steps.length < minSteps) return false;
    if (steps.any((s) => s.title.isEmpty && s.detail.isEmpty)) return false;
    if (answer.isEmpty) return false;
    return RegExp(r'\d').hasMatch(answer);
  }

  (VerifyState, bool) _verify(String? equation, String answer) {
    if (equation == null || equation.trim().isEmpty) {
      // 没给验算式：很多应用题确实写不成一条算式。
      // 这时是"没法验算"，不是"验算通过" —— 界面显示灰色提示，不亮绿勾。
      return (VerifyState.unverifiable, false);
    }
    final exprV = ExprEval.eval(equation);
    if (exprV == null) return (VerifyState.mismatch, true);
    final ansNum = Rational.tryParse(answer.trim());
    if (ansNum == null) return (VerifyState.mismatch, false);
    return (ExprEval.matches(exprV, ansNum) ? VerifyState.exact : VerifyState.mismatch, false);
  }

  (List<SolveStep>, String, String, String?, String?) _parse(String text) {
    var t = text.trim();
    if (t.startsWith('```')) {
      t = t.replaceFirst(RegExp(r'^```(json)?'), '').trim();
      if (t.endsWith('```')) t = t.substring(0, t.length - 3).trim();
    }
    final a = t.indexOf('{');
    final b = t.lastIndexOf('}');
    if (a < 0 || b <= a) {
      // 模型没守 JSON 约定：整段话兜底成一步，会被判"不完整"，不冒充讲完
      return ([SolveStep(title: '讲解', detail: t)], '', '', null, t);
    }
    try {
      final j = jsonDecode(t.substring(a, b + 1)) as Map<String, Object?>;
      final steps = <SolveStep>[];
      for (final s in (j['steps'] as List? ?? const [])) {
        if (s is Map) {
          steps.add(SolveStep(
            title: (s['title'] ?? '').toString(),
            detail: (s['detail'] ?? '').toString(),
            math: (s['math'] ?? '').toString(),
          ));
        }
      }
      return (
        steps,
        (j['answer'] ?? '').toString(),
        (j['unit'] ?? '').toString(),
        (j['equation'] as String?)?.toString(),
        t,
      );
    } catch (_) {
      return ([SolveStep(title: '讲解', detail: t)], '', '', null, t);
    }
  }
}
