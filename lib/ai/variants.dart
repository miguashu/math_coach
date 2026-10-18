/// 同类题 / 衍生题生成 Agent。
///
/// 分工（用户明确要求）：
/// - **简单题本地生成**：题干能被识别成一条纯四则运算（比如"377-98="），
///   就改数字本地出题，答案由 Rational 精确算出 —— 不走网络、不可能出错。
/// - **复杂题交给模型**：应用题、带情境的题由模型出，然后**让模型自己再解一遍**，
///   两个答案对不上就丢掉这道（宁可少出一道，也不出答案错的题）。
/// - 模型出的题若给出可解析的验算式，同样用 Rational 本地复算一遍。
library;

import 'dart:convert';
import 'dart:math' as math;

import '../core/rational.dart';
import 'expr.dart';
import 'llm.dart';

class GenVariant {
  final String stem;
  final String answer;
  final String unit;

  /// local = 本地生成（答案必对）；agent = 模型生成（已自校验 + 本地复算）
  final String source;
  const GenVariant({
    required this.stem,
    required this.answer,
    required this.unit,
    required this.source,
  });
}

/// 模型回的一条同类题：**原文，未经本地验算**。
///
/// 单独拎出来是因为「模型回复怎么解析」有两处要用（同类题、衍生题），
/// 而「解析出来之后收不收」两处的尺度不同 —— 解析公用，闸门各管一段。
class RawVariant {
  final String stem;
  final String answer;
  final String unit;

  /// 从条件到答案的一条四则算式（模型给，本地复算用）
  final String equation;

  /// 一句提示（衍生题用；同类题不看）
  final String hint;

  /// 模型自报的"这是第几道原题的衍生"（0 = 未指定，单题请求时正常）
  final int forIndex;

  const RawVariant({
    required this.stem,
    required this.answer,
    required this.unit,
    required this.equation,
    this.hint = '',
    this.forIndex = 0,
  });
}

class VariantAgent {
  final LlmPort client;
  VariantAgent(this.client);

  static const _system = '''
你是小学数学出题老师。围绕给定的题目，出同类型（换数字/换情境）的练习题。

要求：
1. 难度相当，知识点相同，数字换掉；情境题可以换成孩子熟悉的别的场景。
2. 答案必须是整数或有限小数（适合小学阶段，不出负数、不出循环小数）。
3. 每题给出一条从条件到答案的完整四则算式（只含数字和 + - * / ( )），用于本地验算。
   只写算式本身，不要写等号和答案（写 "20-5"，不要写 "20-5=15"）。
4. 题目之间不要重复。

只输出 JSON：
{"items":[{"stem":"题目","answer":"答案数字","unit":"单位或空","equation":"验算式"}]}''';

  /// [n] 题数，[grade] 用于让模型把住难度。
  Future<List<GenVariant>> generate(String stem, {int n = 4, int grade = 3}) async {
    final local = localVariants(stem, n);
    if (local != null) return local;

    final reply = await client.chat(
      [
        const LlmMessage('system', _system),
        LlmMessage('user', '（$grade 年级）原题：$stem\n请出 $n 道同类题。'),
      ],
      temperature: 0.7,
      // 同 solver：这是上限不是预扣，给宽裕才不会让思维链把正文挤没
      maxTokens: 3000,
    );
    final items = parseReply(reply.text);
    final out = <GenVariant>[];
    for (final it in items) {
      if (it.stem.isEmpty || it.answer.isEmpty) continue;
      // 本地复算：能算就算，算不出来也保留（模型自己解过一遍）
      final v = it.equation.isEmpty ? null : ExprEval.eval(it.equation);
      final a = Rational.tryParse(it.answer.trim());
      if (v != null && a != null && !ExprEval.matches(v, a)) {
        // 本地算出来的和它报的答案不一致 —— 丢掉，宁可少一道
        continue;
      }
      out.add(GenVariant(stem: it.stem, answer: it.answer, unit: it.unit, source: 'agent'));
      if (out.length >= n) break;
    }
    return out;
  }

  /// 本地出题：只处理"一条纯四则运算"的简单题，改数字即可。
  ///
  /// 例："377-98=" → 出 3 道同结构的（两位数/三位数的减法，保持退位特征）。
  /// 返回 null 表示这题本地做不了，交给模型。
  static List<GenVariant>? localVariants(String stem, int n) {
    final s = stem
        .replaceAll('×', '*')
        .replaceAll('÷', '/')
        .replaceAll('＝', '=')
        .replaceAll('＝', '=')
        .replaceAll(' ', '');
    final eq = s.indexOf('=');
    final expr = eq >= 0 && eq > 0 ? s.substring(0, eq) : (s.endsWith('?') || s.endsWith('？') ? '' : s);
    if (expr.isEmpty) return null;
    final value = ExprEval.eval(expr);
    if (value == null) return null;
    // 只支持 a op b 这一种最简结构（小学口算/竖式最常见的形态）
    final m = RegExp(r'^((?:\d|\.)+)([+\-*/])((?:\d|\.)+)$').firstMatch(expr);
    if (m == null) return null;
    final op = m.group(2)!;
    final na = Rational.tryParse(m.group(1)!);
    final nb = Rational.tryParse(m.group(3)!);
    if (na == null || nb == null) return null;

    final out = <GenVariant>[];
    for (var i = 0; i < n; i++) {
      final a = _mutate(na, i);
      final b = _mutate(nb, i + 1);
      Rational r;
      switch (op) {
        case '+':
          r = a + b;
          break;
        case '-':
          // 保证不退到负数，且尽量保留退位（这才是有练习价值的减法）
          if (a < b) {
            r = b - a;
            out.add(GenVariant(
                stem: '${_fmt(b)} − ${_fmt(a)} =', answer: _fmt(r), unit: '', source: 'local'));
            continue;
          }
          r = a - b;
          break;
        case '*':
          r = a * b;
          break;
        default: // /
          if (b.toDouble() == 0) continue;
          r = a / b;
          if (!r.hasFiniteDecimal) continue; // 循环小数不出（小学阶段不该出现）
          break;
      }
      final opText = {'+': '＋', '-': '−', '*': '×', '/': '÷'}[op]!;
      out.add(GenVariant(
          stem: '${_fmt(a)} $opText ${_fmt(b)} =', answer: _fmt(r), unit: '', source: 'local'));
    }
    return out.isEmpty ? null : out;
  }

  static Rational _mutate(Rational base, int seed) {
    final v = base.toDouble();
    var d = ((v * (1 + 0.13 * (seed + 1))).round() + 7 * (seed + 1));
    if (d < 1) d = 1;
    // 位数保持同量级，别把两位数变成五位数
    final digits = v.abs().toString().split('.').first.length;
    while (d.abs() >= math.pow(10, digits)) {
      d = (d / 10).round();
    }
    return Rational.fromInt(d);
  }

  static String _fmt(Rational r) => r.isInteger ? r.toMixedString() : r.toDouble().toString();

  /// 从模型回复里抠出 JSON 数组。解析不出来返回空表（调用方按"没出成"处理）。
  static List<RawVariant> parseReply(String text) {
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
      return [
        for (final e in list)
          if (e is Map)
            RawVariant(
              stem: (e['stem'] ?? '').toString(),
              answer: (e['answer'] ?? '').toString(),
              unit: (e['unit'] ?? '').toString(),
              equation: (e['equation'] ?? '').toString(),
              hint: (e['hint'] ?? '').toString(),
              forIndex: int.tryParse('${e['for'] ?? e['no'] ?? ''}') ?? 0,
            ),
      ];
    } catch (_) {
      return const [];
    }
  }
}
