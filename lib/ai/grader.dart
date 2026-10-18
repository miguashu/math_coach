/// AI 判卷 Agent：拍一张孩子手写答案的照片，模型只负责"认字"，
/// **对不对永远由本地判分规则定**（[QuizAnswer.check]），批语由模型写。
///
/// 为什么判分不能交给模型（用户原话："我需要有个判卷子的 ai Agent，
/// 出的题能根据照片进行判断"）：
///   模型认字会错 —— 把 "395" 认成 "396"、把 "8……2" 认成 "8.2"。
///   如果让模型既认字又判分，它认错了就会顺手判错，孩子白背一个错题。
///   所以这里拆成三步，每步只干一件事：
///
///   1. **认字**（vision）：把手写答案读成文本，认不出就留空 + 注明，
///      不许猜。照片里印着的题干不抄。
///   2. **判分**（本地）：[QuizAnswer.check] 做规范化比较
///      （全角半角、单位剥离、余数写法、数值容差都在这里）。
///      模型认错字会被这一步逮住 —— 而且用户在确认前还能改。
///   3. **批语**（chat）：只给本地判为错的题写一两句批语。
///      模型不决定对错，它只是"解释为什么错"。
///
/// 和 quizgen / solver 同一套哲学：**答案与判定本地算，模型只补文字**。
library;

import 'dart:convert';

import '../quiz/question.dart';
import 'llm.dart';

/// 模型从照片里读出的一道题的手写答案。
class GradeRead {
  /// 题号（1 起，对应题目列表里的"第 N 题"）
  final int no;

  /// 认出的手写答案原文（认不出 = 空串）
  final String answer;

  /// 识别备注（"第 2 题字迹潦草"之类；空 = 清晰）
  final String note;

  const GradeRead({required this.no, required this.answer, this.note = ''});

  /// 认不出或看不清：这两种都不能拿去判分 —— 没看清就判错是冤枉孩子。
  bool get unclear => answer.trim().isEmpty || note.trim().isNotEmpty;
}

/// 认卷结果。
class GradeReadResult {
  final List<GradeRead> items;

  /// 失败原因（网络/配置/模型不守格式）；items 非空时仍算成功
  final String? error;
  final int latencyMs;
  final int totalTokens;
  final String model;

  const GradeReadResult({
    required this.items,
    this.error,
    this.latencyMs = 0,
    this.totalTokens = 0,
    this.model = '',
  });

  bool get ok => items.isNotEmpty;
}

/// 一道题判完的总账（认字 + 本地判分 + 批语）。
class GradeVerdict {
  final String questionId;

  /// 模型认出的手写答案（用户可能改过，以最终文本为准）
  final String readText;

  /// 本地判分结果。null = 未识别，不判错也不判对。
  final bool? correct;

  /// 识别时是否不确定（字迹不清等），界面据此提示用户核对
  final bool uncertain;

  /// AI 批语（答错时可能有）
  final String? comment;

  const GradeVerdict({
    required this.questionId,
    required this.readText,
    this.correct,
    this.uncertain = false,
    this.comment,
  });
}

/// 判卷总结。
class GradeSummary {
  final List<GradeVerdict> verdicts;
  final int correctCount;
  final int wrongCount;

  /// 没认出答案的题数（不判错）
  final int unreadCount;
  final String? error;

  const GradeSummary({
    required this.verdicts,
    required this.correctCount,
    required this.wrongCount,
    required this.unreadCount,
    this.error,
  });

  bool get ok => verdicts.isNotEmpty;
}

class GradeAgent {
  final LlmPort client;

  /// 主识别模型不可用时的备胎模型名（空 = 不降级）。
  final String fallbackModel;

  GradeAgent(this.client, {this.fallbackModel = ''});

  /// 认卷提示词。指令和题单合成**一条 user 消息**发给视觉模型：
  /// 有的视觉端点对 system 消息支持不完整，而项目里已验证可用的
  /// 拍照识题（ocr.dart）正是单 user 消息 + base64 图的格式。
  static const _system = '''
你是一位小学数学阅卷老师。用户会给你一张学生手写答卷的照片和题目列表。
你的任务**只是认字**：把每道题手写的答案读出来。判断对错由别的系统负责，
你不要猜对错，也不要改答案。

硬性要求：
1. 按题号对应：题目列表里"第 N 题"的答案，就在照片里找第 N 题旁边手写的内容。
2. 手写答案**原样抄出**：数字、单位、小数、分数、余数写法（如 "8……2"）
   都保持原样，不要换算、不要约分。
3. 照片里通常同时印着题干和手写答案：**只抄手写部分**，不要抄印刷体题干。
4. 字迹难以辨认：answer 填空字符串，在 note 里说明（如"第2题字迹潦草"）。
   不许猜一个数字填进去。
5. 某题旁边没有手写答案：answer 填空字符串，note 写"未作答"。
6. 只输出 JSON，不要其他文字：
{"items":[{"no":题号,"answer":"手写答案原文","note":"看不清就写原因"}]}''';

  /// 一次认卷调用 + 解析。失败不抛异常，错误写进 [GradeReadResult.error]。
  Future<GradeReadResult> readAnswers({
    required String imageBase64,
    required List<QuizQuestion> questions,
  }) async {
    if (questions.isEmpty) {
      return const GradeReadResult(items: [], error: '没有需要批改的题目');
    }
    try {
      final reply = await _chat(
        [LlmMessage('user', '$_system\n\n${_userPrompt(questions)}',
            imageBase64: imageBase64)],
        temperature: 0.1,
        maxTokens: 3000,
      );
      final items = _parse(reply.text);
      if (items.isEmpty) {
        return GradeReadResult(
          items: const [],
          error: '没能从照片里认出答案（可能是拍摄不清晰），可以重拍或手动输入',
          latencyMs: reply.latencyMs,
          totalTokens: reply.totalTokens,
          model: reply.model,
        );
      }
      return GradeReadResult(
        items: items,
        latencyMs: reply.latencyMs,
        totalTokens: reply.totalTokens,
        model: reply.model,
      );
    } on LlmError catch (e) {
      return GradeReadResult(items: [], error: e.message);
    } catch (e) {
      return GradeReadResult(items: [], error: '认卷失败：$e');
    }
  }

  /// 给答错的题写批语（一次批量调用）。
  ///
  /// [wrong] 是本地已判为错的题（题号从 1 起）。返回 题号 → 批语。
  /// 批语是"解释错因"，不是"判定对错" —— 判定在调用前就由本地做完了。
  /// 任何失败都返回空 map：没有批语不该拦住批改本身。
  Future<Map<int, String>> writeComments({
    required List<({int no, QuizQuestion q, String read})> wrong,
    int grade = 3,
  }) async {
    if (wrong.isEmpty) return const {};
    final out = <int, String>{};
    // 一批最多 6 题：批语要短，但推理模型的思维链会吃预算，
    // 堆太多题只会得到半截 JSON。
    for (var i = 0; i < wrong.length; i += 6) {
      final batch = wrong.skip(i).take(6).toList();
      try {
        final reply = await _chat(
          [
            const LlmMessage('system', _commentSystem),
            LlmMessage('user', _commentPrompt(batch, grade)),
          ],
          temperature: 0.4,
          maxTokens: 4000,
        );
        out.addAll(_parseComments(reply.text));
      } catch (_) {
        // 批语失败不影响判卷结果
      }
    }
    return out;
  }

  static const _commentSystem = '''
你是一位小学数学老师，给答错题的孩子写批语。只输出 JSON：
{"items":[{"no":1,"comment":"一两句话"}]}

硬性要求：
1. 每条批语一两句话：先说错在哪（算式错/概念混/漏步骤/抄错数），
   再给一句鼓励。像老师写在卷子边上的话，不说教。
2. 不许复述题目，不许再讲一遍完整步骤（讲解系统会做），
   不许出现"正确答案是X"（判分系统已经显示过了）。
3. 语言适合该年级的小学生。''';

  String _commentPrompt(
      List<({int no, QuizQuestion q, String read})> batch, int grade) {
    final b = StringBuffer()
      ..writeln('（$grade 年级）以下题孩子答错了，请给每条写一句批语：');
    for (final w in batch) {
      b.writeln('第 ${w.no} 题：${_clip(w.q.stem)}');
      b.writeln('  孩子写的：${w.read.isEmpty ? "（空）" : w.read}');
      b.writeln('  这题的正确思路：${w.q.solutionSteps.take(2).join("；")}');
    }
    return b.toString();
  }

  Map<int, String> _parseComments(String text) {
    final items = _jsonItems(text);
    final out = <int, String>{};
    for (final it in items) {
      final no = int.tryParse((it['no'] ?? '').toString());
      final c = (it['comment'] ?? '').toString().trim();
      if (no != null && c.isNotEmpty) out[no] = c;
    }
    return out;
  }

  // ── 内部 ────────────────────────────────────────

  Future<LlmReply> _chat(
    List<LlmMessage> messages, {
    required double temperature,
    required int maxTokens,
  }) async {
    try {
      return await client.chat(
        messages,
        vision: true,
        temperature: temperature,
        maxTokens: maxTokens,
        timeout: const Duration(seconds: 120),
      );
    } on LlmError catch (e) {
      // 聚合站的模型列表会变动：主模型报"模型不存在/不支持"时换备胎再试
      if (!e.modelMissing || fallbackModel.isEmpty) rethrow;
      return client.chat(
        messages,
        vision: true,
        temperature: temperature,
        maxTokens: maxTokens,
        timeout: const Duration(seconds: 120),
        modelOverride: fallbackModel,
      );
    }
  }

  String _userPrompt(List<QuizQuestion> questions) {
    final b = StringBuffer()
      ..writeln('请认以下 ${questions.length} 道题的手写答案：');
    for (var i = 0; i < questions.length; i++) {
      b.writeln('第 ${i + 1} 题：${_clip(questions[i].stem)}');
    }
    return b.toString();
  }

  /// 题干截断：整段题干对"找手写答案"没有增量，还占 token。
  static String _clip(String s) {
    final t = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    return t.length <= 80 ? t : '${t.substring(0, 80)}…';
  }

  List<GradeRead> _parse(String text) {
    final items = _jsonItems(text);
    final out = <GradeRead>[];
    for (final it in items) {
      final no = int.tryParse((it['no'] ?? '').toString());
      if (no == null || no < 1) continue;
      out.add(GradeRead(
        no: no,
        answer: (it['answer'] ?? '').toString().trim(),
        note: (it['note'] ?? '').toString().trim(),
      ));
    }
    return out;
  }

  /// 模型偶尔不守 JSON 约定（包一层 ``` 或者多说两句话）。
  /// 只取第一个 { 到最后一个 } 之间的内容；取不出来就返回空，
  /// 由上层按"没认出"处理 —— 不猜。
  static List<Map<String, Object?>> _jsonItems(String text) {
    var t = text.trim();
    if (t.startsWith('```')) {
      t = t.replaceFirst(RegExp(r'^```(json)?'), '').trim();
      if (t.endsWith('```')) t = t.substring(0, t.length - 3).trim();
    }
    final a = t.indexOf('{');
    final b = t.lastIndexOf('}');
    if (a < 0 || b <= a) return const [];
    try {
      final j = jsonDecode(t.substring(a, b + 1)) as Map<String, Object?>;
      final list = (j['items'] as List?) ?? const [];
      final out = <Map<String, Object?>>[];
      for (final e in list) {
        if (e is Map) out.add(e.cast<String, Object?>());
      }
      return out;
    } catch (_) {
      return const [];
    }
  }
}
