/// 拍照识题 Agent（视觉模型 + OCR 提示词）。
///
/// 模型只做两件事：把图片里的题**认出来**（OCR）并**结构化**成题干文本；
/// 绝不允许它输出坐标或直接给几何图形定尺寸（项目的第一条铁律）。
/// 认出来的文本交给家长/孩子确认后再进 [KidSolver] 讲解。
///
/// 2026-10-17：家长反馈"只能出现一道题，不太合理" —— 一张卷子照片上往往
/// 有好几道题，原来提示词明确要求"只提取最清晰、最主要的那一道"，
/// 于是每次只认一道，剩下的还得重新拍。现在一次把**全部**题目认回来
/// （上限 8 道，够了：再多的卷子应该分张拍，一张张更清楚）。
library;

import 'dart:convert';

import 'llm.dart';

class OcrResult {
  /// 认出来的**全部**题干（按题号顺序）。第一道就是 [stem]。
  ///
  /// 家长可以逐道改、逐道讲 —— 一道看不清不影响其他题。
  final List<String> items;

  /// 识别时的说明（哪几个字看不清、有没有图）。
  final String? notes;

  final int latencyMs;
  final int totalTokens;
  final String model;

  const OcrResult({
    required this.items,
    required this.latencyMs,
    required this.totalTokens,
    required this.model,
    this.notes,
  });

  /// 第一道题（兼容旧调用方：单题场景下这就是全部）。
  String get stem => items.isEmpty ? '' : items.first;

  /// 认回来几道题。
  int get count => items.length;
}

class PhotoReader {
  final LlmPort client;

  /// 主识别模型不可用时的备胎模型名（空 = 不降级）。
  final String fallbackModel;

  PhotoReader(this.client, {this.fallbackModel = ''});

  static const _prompt = '''
这是一张小学数学题目的照片。请做 OCR 并结构化：

1. 把照片里**每一道**题目都完整抄出来（含数字、单位、选项、括号），按从上到下的顺序。
2. 最多抄 8 道；超出 8 道就抄前 8 道并在 notes 里说明"还有更多题"。
3. 每道题单独一项，不要把几道题合并成一项。
4. 如果照片里有几何图形：不要描述坐标，只用一行说明图的形状与已知条件
   （例如"直角三角形，底 6 cm，高 4 cm"），写进该项的 notes。
5. 看不清的地方用 □ 占位，不要猜。

只输出 JSON，不要其他文字：
{"items":[{"stem":"第 1 题原文","notes":"补充说明，没有就空字符串"},
          {"stem":"第 2 题原文","notes":""}]}''';

  /// 识题。主模型报「模型不存在/不支持」时自动换备胎再来一次 ——
  /// 聚合站的模型列表会变动，硬失败一次就让家长以为"拍照坏了"不划算。
  Future<OcrResult> read(String imageBase64) async {
    try {
      return await _once(imageBase64, null);
    } on LlmError catch (e) {
      if (!e.modelMissing || fallbackModel.isEmpty) rethrow;
      return await _once(imageBase64, fallbackModel);
    }
  }

  Future<OcrResult> _once(String imageBase64, String? model) async {
    final reply = await client.chat(
      [LlmMessage('user', _prompt, imageBase64: imageBase64)],
      vision: true,
      temperature: 0.1,
      // max_tokens 是**上限**不是预扣，用不到不花钱 —— 所以给宽裕些，
      // 免得推理模型把预算花在思维链上、正文被截断。
      // 多题要抄的原文更多，从 2000 放到 3000。
      maxTokens: 3000,
      timeout: const Duration(seconds: 120),
      modelOverride: model,
    );
    final parsed = _parse(reply.text);
    return OcrResult(
      items: parsed.$1,
      notes: parsed.$2,
      latencyMs: reply.latencyMs,
      totalTokens: reply.totalTokens,
      model: reply.model,
    );
  }

  /// 解析模型回复。同时认两种格式：
  /// - 新的 `{"items":[{stem,notes}, ...]}`（多题）；
  /// - 旧的 `{"stem":..., "notes":...}`（单题，兜底）；
  /// - 模型不守 JSON 时整段当一道题（界面上家长自己改）。
  (List<String>, String?) _parse(String text) {
    var t = text.trim();
    if (t.startsWith('```')) {
      t = t.replaceFirst(RegExp(r'^```(json)?'), '').trim();
      if (t.endsWith('```')) t = t.substring(0, t.length - 3).trim();
    }
    final a = t.indexOf('{');
    final b = t.lastIndexOf('}');
    if (a < 0 || b <= a) return (t.isEmpty ? const [] : [t], null);
    try {
      final j = jsonDecode(t.substring(a, b + 1)) as Map<String, Object?>;
      final list = j['items'];
      if (list is List && list.isNotEmpty) {
        final stems = <String>[];
        String? notes;
        for (final e in list) {
          if (e is! Map) continue;
          final s = (e['stem'] ?? '').toString().trim();
          if (s.isEmpty) continue;
          stems.add(s);
          final n = (e['notes'] ?? '').toString().trim();
          if (n.isNotEmpty) notes = (notes == null ? n : '$notes；$n');
        }
        if (stems.isNotEmpty) return (stems, notes);
      }
      // 旧格式 / 只有一个 stem 字段
      final stem = (j['stem'] ?? '').toString().trim();
      final notes = (j['notes'] as String?)?.toString().trim();
      return (
        stem.isEmpty ? [t] : [stem],
        (notes == null || notes.isEmpty) ? null : notes
      );
    } catch (_) {
      return (t.isEmpty ? const [] : [t], null);
    }
  }
}
