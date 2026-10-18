/// 真机联网实测（手动跑，不进日常回归）：`dart run test/live_agicto.dart`
///
/// 为什么单独有一个脚本：AI 层的逻辑（打回重做、验算三态、降级重试）
/// 已经被 ai_manual.dart 用假模型覆盖了 49 条断言，但**真链路一直没验过** ——
/// HTTP 通不通、模型返回的 JSON 长什么样、那个模型到底能不能收图片，
/// 这些只有拿真 key 打一次才知道。
///
/// 三条主链路各打一遍：
///   ① 讲解 Agent（含本地精确验算，打印 exact/unverifiable/mismatch）
///   ② 拍照识图（真图 base64 → 题干）
///   ③ 同类题生成（简单题本地出 / 应用题模型出 + 本地复算）
library;

import 'dart:convert';
import 'dart:io';

import 'package:math_coach/ai/config.dart';
import 'package:math_coach/ai/llm.dart';
import 'package:math_coach/ai/ocr.dart';
import 'package:math_coach/ai/solver.dart';
import 'package:math_coach/ai/variants.dart';

int _ok = 0;
int _bad = 0;

void ck(String name, bool ok, [String why = '']) {
  if (ok) {
    _ok++;
    print('  ✅ $name');
  } else {
    _bad++;
    print('  ❌ $name${why.isEmpty ? '' : ' → $why'}');
  }
}

Future<void> main(List<String> args) async {
  final img = args.isNotEmpty ? args[0] : 'tool/testdata/probe.png';
  final cfg = AiConfig.fallback;
  final client = LlmClient(cfg);

  print('════════ 真机联网实测 ════════');
  print('供应商   ${cfg.provider}');
  print('地址     ${cfg.baseUrl}  （识别：${cfg.effectiveVisionBaseUrl}）');
  print('解题模型 ${cfg.chatModel}');
  print('识别模型 ${cfg.visionModel}  （备胎 ${cfg.visionFallbackModel}）');
  print('');

  // ── ① 讲解 ────────────────────────────────────────────
  print('【① 讲解 Agent】');
  final cases = <(int, String)>[
    (2, '237 + 158 = ?'),
    (3, '一根绳子长 12 米，先用去 3 米，又用去 4 米，还剩多少米？'),
    (5, '一个长方形，长 9 厘米，宽 6 厘米，面积是多少平方厘米？'),
  ];
  for (final (grade, stem) in cases) {
    print('\n题（$grade 年级）：$stem');
    try {
      final r = await KidSolver(client).solve(stem, grade: grade);
      for (var i = 0; i < r.steps.length; i++) {
        final s = r.steps[i];
        print('   ${i + 1}. ${s.title}');
        if (s.detail.isNotEmpty) print('      ${s.detail}');
        if (s.math.isNotEmpty) print('      算式 ${s.math}');
      }
      print('   答案 ${r.answer}${r.unit}  验算式 ${r.equation ?? "（无）"}');
      print('   验算 ${r.verifyState.label} | 步骤完整=${r.complete} | '
          '尝试 ${r.attempts} 次 | ${r.latencyMs} ms | ${r.totalTokens} tokens | ${r.model}');
      ck('讲了至少 2 步', r.steps.length >= 2, '实际 ${r.steps.length} 步');
      ck('给出了答案', r.answer.isNotEmpty);
      ck('验算没被打成不一致', r.verifyState != VerifyState.mismatch,
          r.verifyState.label);
    } catch (e) {
      _bad++;
      print('   ❌ 讲解失败：$e');
    }
  }

  // ── ② 拍照识图 ────────────────────────────────────────
  print('\n【② 拍照识图】');
  String ocrStem = '';
  try {
    final f = File(img);
    if (!await f.exists()) {
      print('   ⚠ 找不到测试图 $img（用 python 生成一张题目图即可）');
      _bad++;
    } else {
      final b64 = base64Encode(await f.readAsBytes());
      final r = await PhotoReader(client, fallbackModel: cfg.visionFallbackModel)
          .read(b64);
      ocrStem = r.stem;
      print('   图：$img（${b64.length} 字符 base64）');
      print('   认出的题干：${r.stem}');
      if (r.notes != null) print('   备注：${r.notes}');
      print('   ${r.latencyMs} ms | ${r.totalTokens} tokens | 模型 ${r.model}');
      ck('识出了题干', r.stem.isNotEmpty);
      ck('题干里有数字', RegExp(r'\d').hasMatch(r.stem), r.stem);
    }
  } catch (e) {
    _bad++;
    print('   ❌ 识图失败：$e');
  }

  // 识出来的题直接接着讲 —— 这才是真实使用路径（拍照 → 讲解）
  if (ocrStem.isNotEmpty) {
    print('\n【②b 拍照 → 直接讲解（真实链路）】');
    try {
      final r = await KidSolver(client).solve(ocrStem, grade: 3);
      print('   ${r.steps.length} 步 | 答案 ${r.answer}${r.unit} | '
          '${r.verifyState.label} | ${r.latencyMs} ms');
      for (final s in r.steps) {
        print('   · ${s.title}${s.math.isEmpty ? '' : '  ${s.math}'}');
      }
      ck('拍照后能接着讲', r.steps.isNotEmpty && r.answer.isNotEmpty);
    } catch (e) {
      _bad++;
      print('   ❌ $e');
    }
  }

  // ── ③ 同类题 ──────────────────────────────────────────
  print('\n【③ 同类题】');
  try {
    final local = await VariantAgent(client).generate('377-98=', n: 3);
    print('   简单题（本地生成，不联网）：');
    for (final v in local) {
      print('   · ${v.stem} 答案 ${v.answer} [${v.source}]');
    }
    ck('简单题走本地生成', local.isNotEmpty && local.every((v) => v.source == 'local'));
  } catch (e) {
    _bad++;
    print('   ❌ $e');
  }
  try {
    final vs = await VariantAgent(client)
        .generate('小明买 3 支铅笔，每支 2 元，一共花了多少元？', n: 3, grade: 2);
    print('   应用题（模型生成 + 本地复算）：');
    for (final v in vs) {
      print('   · ${v.stem} → ${v.answer}${v.unit} [${v.source}]');
    }
    ck('应用题由模型生成', vs.isNotEmpty && vs.every((v) => v.source == 'agent'));
  } catch (e) {
    _bad++;
    print('   ❌ $e');
  }

  // ── ④ 推理模型的 token 预算自愈（2026-10-16 真机反馈的缺陷）────
  // 现场：App「测试连接」写死 maxTokens:16，而 deepseek-v4-flash 是推理模型，
  // 16 个 token 全被思维链（reasoning_content）吃掉，content 是空字符串 →
  // 解题与识别两项测试**同时**报失败。这里直接复现那个参数，
  // 验证客户端会自己把预算补上去，而不是让家长看到"返回了空内容"。
  print('\n【④ 推理模型的 token 预算自愈】');
  try {
    final r = await LlmClient(cfg).chat(
      [const LlmMessage('user', '回复两个字：正常')],
      maxTokens: 16,
    );
    print('   只给 16 tokens 也拿到了回复："${r.text.trim()}"（共 ${r.totalTokens} tokens）');
    ck('预算被思维链吃光时自动补发', r.text.trim().isNotEmpty);
  } catch (e) {
    _bad++;
    print('   ❌ 没能自愈：$e');
  }

  print('\n════════ 实测结果：✅ $_ok  ❌ $_bad ════════');
  if (_bad > 0) exit(1);
}
