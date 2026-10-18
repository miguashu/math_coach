/// 「衍生题必须同算法」回归用例（离线，纯本地，不联网）。
///
/// 本机跑不了 `dart test`（Dart VM 无法以管道模式 spawn 子进程），
/// 断言写成可直接 `dart run` 的脚本。
///
/// 这一篇专门守一件事：**衍生题不能换了算法**。
///
/// 起因是模拟器上真跑出来的四道题（判卷 → 衍生题 → 题库）：
///
/// | 源题 | 当时衍生成 | 错在哪 |
/// |---|---|---|
/// | 长方形**面积** 8×5 | 长12宽4 的**周长** | 换了公式（`(a+b)×2` ≠ `a×b`） |
/// | 不退位**减** 731−463 | **573 + 652** | 减法变加法 |
/// | **倍的认识**（3+3×2，两步） | 每盒38支买3盒（一步乘） | 少一步 |
/// | **简单购物**（60−6×4，两步找零） | 一支28元买11支（一步乘） | 少一步 |
///
/// 四道的答案本身都没算错，但孩子练的是**另一个考点** ——
/// 连对两次会在题库里留下假的"已掌握"，比不出题更糟。
/// 根因是映射只看题型名，不看算法结构（`rect` 既有面积也有周长）。
///
/// 所以这个脚本用**真实出题器产出的题干**当输入，而不是手写题干：
/// 手写题干只能证明"我想到的情况对了"，真实题干才能证明"线上出的题都对"。
///
/// 跑法：dart run test/derive_shape_manual.dart
library;

import 'dart:io';

import 'package:math_coach/ai/derive.dart';
import 'package:math_coach/quiz/generator.dart';
import 'package:math_coach/quiz/question.dart';
import 'package:math_coach/store/bank.dart';
import 'package:math_coach/variant/generator.dart';
import 'package:math_coach/variant/mapping.dart';

int _pass = 0;
int _fail = 0;

void ck(String name, bool ok, [String why = '']) {
  if (ok) {
    _pass++;
    print('PASS  $name');
  } else {
    _fail++;
    print('FAIL  $name ${why.isEmpty ? '' : '→ $why'}');
  }
}

/// 本地有同算法模板、且结构可判的 10 个题型。
const _supported = <String>[
  'add', 'sub', 'mul', 'timesAs', 'divRem',
  'rect', 'triangle', 'circleArea', 'unitConv', 'shopping',
];

/// 本地**刻意不接**的题型：名字相关但算法不同，交给模型按原题干出。
const _excluded = <String>[
  'mixOps', // 运算顺序
  'interval', // 段数与点数
  'average', // 一条式子既有乘也有除
  'trapezoid', // (上底+下底)×高÷2
  'parallelogram', // 底×高（还有"高是垂直那条"的坑）
  'circlePerim', // 2πr（本地只有 πr²）
  'composite', // 长方形接半圆
  'lattice', // 格点多边形（鞋带公式）
  'cubeNet', // 展开图
  'cuboid', // 体积
  'cuboidSurface', // 表面积
  'cylinder', // 圆柱体积
  'fractionOf', // 求一个数的几分之几 = ÷分母×分子，不是分数加减
];

List<int> _ints(String s) =>
    RegExp(r'\d+').allMatches(s).map((m) => int.parse(m.group(0)!)).toList();

/// 按结构独立复算答案 —— **不看生成器怎么写的**，只按"这个结构应该怎么算"。
/// 这是这套用例的核心：它和被测代码走的是两条独立的路径。
double? _expectByShape(VariantShape shape, String stem) {
  final n = _ints(stem);
  switch (shape) {
    case VariantShape.add:
      return (n[0] + n[1]).toDouble();
    case VariantShape.sub:
      return (n[0] - n[1]).toDouble();
    case VariantShape.mul:
      return (n[0] * n[1]).toDouble();
    case VariantShape.timesOneStep:
      return (n[0] * n[1]).toDouble();
    case VariantShape.mulThenAdd:
      return (n[0] + n[0] * n[1]).toDouble();
    case VariantShape.mulThenSub:
      // 小明买了 c 支…每支 p 元…付 f 元，应找回：f − p×c
      return (n[2] - n[1] * n[0]).toDouble();
    case VariantShape.divRem:
      return (n[0] ~/ n[1]).toDouble();
    case VariantShape.rectArea:
      return (n[0] * n[1]).toDouble();
    case VariantShape.rectPerim:
      return (2 * (n[0] + n[1])).toDouble();
    case VariantShape.triArea:
      return (n[0] * n[1] / 2).toDouble();
    case VariantShape.circleArea:
      return n[0] * n[0] * 3.14;
    case VariantShape.unitConv:
      // 换算倍率（100 / 1000）在题干里读不出，单独校验
      return null;
  }
}

/// 题干里该出现什么、不该出现什么 —— 直接对应上表那四个 bug。
List<String> _structureViolations(VariantShape shape, String stem) {
  final bad = <String>[];
  bool has(String s) => stem.contains(s);
  switch (shape) {
    case VariantShape.sub:
      if (!has('−')) bad.add('减法题的题干里没有减号');
      if (has('+')) bad.add('减法题里出现了加号');
    case VariantShape.add:
      if (!has('+')) bad.add('加法题的题干里没有加号');
    case VariantShape.rectArea:
      if (!has('面积')) bad.add('面积题没问面积');
      if (has('周长')) bad.add('面积题问成了周长');
    case VariantShape.rectPerim:
      if (!has('周长')) bad.add('周长题没问周长');
      if (has('面积')) bad.add('周长题问成了面积');
    case VariantShape.timesOneStep:
      if (!has('倍')) bad.add('倍数题没有"倍"');
      if (has('一共')) bad.add('一步倍数题问成了"一共"（那是两步）');
    case VariantShape.mulThenAdd:
      if (!has('倍')) bad.add('倍数题没有"倍"');
      if (!has('一共')) bad.add('两步倍数题没问"一共"，会漏掉最后一步');
    case VariantShape.mulThenSub:
      if (!has('找回')) bad.add('找零题没问"找回"');
    case VariantShape.divRem:
      if (!has('还剩')) bad.add('有余数除法没问"还剩"');
    case VariantShape.mul:
    case VariantShape.triArea:
    case VariantShape.circleArea:
    case VariantShape.unitConv:
      break;
  }
  return bad;
}

Future<void> main() async {
  // ── 取材：用真实出题器把 1~6 年级各出一批，按题型收集真实题干 ──
  final byKind = <String, List<QuizQuestion>>{};
  for (var g = 1; g <= 6; g++) {
    final qs = QuizGenerator(seed: 20261016).generateMany(grade: g, count: 260);
    for (final q in qs) {
      byKind.putIfAbsent(q.kind, () => []).add(q);
    }
  }
  print('取材：${byKind.length} 种题型，'
      '${byKind.values.fold(0, (a, b) => a + b.length)} 道题\n');

  // ── 1) 覆盖检查：这 10 个题型的本地模板真的被用到了吗 ──
  for (final k in _supported) {
    final n = byKind[k]?.length ?? 0;
    ck('取材覆盖到 $k', n > 0, '真实题干里没抽到这种题（测试将失去意义）');
  }

  // ── 2) 支持列表：每道题都必须判出结构、都必须同算法 ──
  var derivedTotal = 0;
  for (final k in _supported) {
    final sources = byKind[k] ?? const <QuizQuestion>[];
    if (sources.isEmpty) continue;

    final noRecipe = <String>[];
    final badStructure = <String>[];
    final badAnswer = <String>[];
    final wrongCount = <String>[];
    var shapes = <VariantShape>{};

    for (var i = 0; i < sources.length; i++) {
      final q = sources[i];
      final r = localRecipeFor(quizKind: q.kind, stem: q.stem);
      if (r == null) {
        noRecipe.add('${q.id} :: ${q.stem}');
        continue;
      }
      shapes.add(r.shape);

      // 逐道真跑一遍衍生（固定种子，结果可复现）
      final out = await DeriveAgent(seed: 1000 + i).deriveAll([q]);
      final mine = out.entries.where((e) => e.sourceQuestionId == q.id).toList();
      if (mine.length != DeriveAgent.perQuestion) {
        wrongCount.add('${q.id} 只出了 ${mine.length} 道');
      }
      for (final e in mine) {
        derivedTotal++;
        if (e.origin != 'local') {
          badStructure.add('${e.stem} ← 不是本地出的（origin=${e.origin}）');
        }
        final v = _structureViolations(r.shape, e.stem);
        if (v.isNotEmpty) badStructure.add('${e.stem} :: ${v.join('；')}');
        final exp = _expectByShape(r.shape, e.stem);
        final got = e.answerValue;
        if (exp != null && got != null && (exp - got).abs() > 1e-9) {
          badAnswer.add('${e.stem} 本地复算=$exp 入库=$got');
        }
        // 换算题的倍率在题干单位里，单独看
        if (r.shape == VariantShape.unitConv) {
          final n = _ints(e.stem);
          final ok = e.answerValue == n[0] * 100 || e.answerValue == n[0] * 1000;
          if (!ok) badAnswer.add('${e.stem} 换算答案=${e.answerValue}');
        }
      }
    }

    ck('$k：每道题都判得出结构（${sources.length} 道，结构 ${shapes.map((s) => s.name).join('/')}）',
        noRecipe.isEmpty, noRecipe.take(2).join(' | '));
    ck('$k：衍生题与原题同算法', badStructure.isEmpty,
        badStructure.take(2).join(' | '));
    ck('$k：衍生题答案与独立复算一致', badAnswer.isEmpty,
        badAnswer.take(2).join(' | '));
    ck('$k：每道都出满 ${DeriveAgent.perQuestion} 道', wrongCount.isEmpty,
        wrongCount.take(2).join(' | '));
  }

  // ── 3) 这一批**必须**落到模型那条路（本地名字像、算法不是）──
  for (final k in _excluded) {
    final sources = byKind[k] ?? const <QuizQuestion>[];
    if (sources.isEmpty) continue;
    final leaked = <String>[];
    for (final q in sources) {
      if (localRecipeFor(quizKind: q.kind, stem: q.stem) != null) {
        leaked.add('${q.id} :: ${q.stem}');
      }
    }
    ck('$k 不本地映射（名字相关 ≠ 算法相同）', leaked.isEmpty,
        leaked.take(2).join(' | '));
  }

  // ── 4) 关键结构必须分得开：同一题型里藏着的两种算法 ──
  {
    final timesTwo = byKind['timesAs']!
        .firstWhere((q) => q.stem.contains('一共'), orElse: () => byKind['timesAs']!.first);
    final timesOne = byKind['timesAs']!
        .firstWhere((q) => !q.stem.contains('一共'), orElse: () => byKind['timesAs']!.first);
    final rTwo = localRecipeFor(quizKind: 'timesAs', stem: timesTwo.stem);
    final rOne = localRecipeFor(quizKind: 'timesAs', stem: timesOne.stem);
    ck('倍的认识：问"一共"判成两步', rTwo?.shape == VariantShape.mulThenAdd,
        '${rTwo?.shape} ← ${timesTwo.stem}');
    ck('倍的认识：问"有多少本"判成一步',
        rOne?.shape == VariantShape.timesOneStep, '${rOne?.shape} ← ${timesOne.stem}');

    final rectArea = byKind['rect']!.firstWhere((q) => q.stem.contains('面积'),
        orElse: () => byKind['rect']!.first);
    final rectPerim = byKind['rect']!.firstWhere((q) => q.stem.contains('周长'),
        orElse: () => byKind['rect']!.first);
    final rA = localRecipeFor(quizKind: 'rect', stem: rectArea.stem);
    final rP = localRecipeFor(quizKind: 'rect', stem: rectPerim.stem);
    ck('长方形：问面积判成 rectArea', rA?.shape == VariantShape.rectArea,
        '${rA?.shape} ← ${rectArea.stem}');
    ck('长方形：问周长判成 rectPerim', rP?.shape == VariantShape.rectPerim,
        '${rP?.shape} ← ${rectPerim.stem}');
  }

  // ── 5) 结构判不出来时不许猜：退回模型（而不是本地硬凑）──
  {
    ck('rect 题干读不出面积/周长 → 不接',
        localRecipeFor(quizKind: 'rect', stem: '一个长方形，长 8 厘米，宽 5 厘米，求它的对角线。') == null);
    ck('timesAs 题干里没有"倍" → 不接',
        localRecipeFor(quizKind: 'timesAs', stem: '图书角有一些书，又买来 3 本，现在有多少本？') == null);
    ck('shopping 但不是找零 → 不接',
        localRecipeFor(quizKind: 'shopping', stem: '一支钢笔 28 元，买 3 支要花多少元？') == null);
    ck('题型对不上 → 不接',
        localRecipeFor(quizKind: 'cylinder', stem: '一个圆柱的底面半径是 3 厘米，高是 5 厘米，体积是多少？') == null);
  }

  // ── 6) 结构命令是命令：不兼容的结构不许被模板悄悄忽略 ──
  {
    ck('加减模板 + 要求除法 → 拒绝生成',
        !VariantGenerator.shapeFits(VariantKind.addSub3, VariantShape.divRem));
    ck('乘法模板 + 要求面积 → 拒绝生成',
        !VariantGenerator.shapeFits(VariantKind.mul2x1, VariantShape.rectArea));
    // 带约束生成 40 次，减法就必须次次是减法
    final gen = VariantGenerator(seed: 7);
    final vs = gen.generateMany(VariantKind.addSub3, 40, shape: VariantShape.sub);
    ck('要求减法的批量生成全是减法',
        vs.length == 40 && vs.every((v) => v.stem.contains('−') && !v.stem.contains('+')),
        '拿到 ${vs.length} 道');
    final ra = gen.generateMany(VariantKind.rectAreaPerimeter, 30,
        shape: VariantShape.rectArea);
    ck('要求面积的批量生成全是面积题',
        ra.length == 30 && ra.every((v) => v.stem.contains('面积') && !v.stem.contains('周长')),
        '拿到 ${ra.length} 道');
  }

  // ── 7) 题库拿到的答案就是要练的答案，不能是"答案字符串"里含单位而算错 ──
  {
    final src = byKind['shopping']!.first;
    final out = await DeriveAgent(seed: 3).deriveAll([src]);
    ck('购物错题：衍生题也是两步找零', out.entries.isNotEmpty &&
        out.entries.every((e) => e.stem.contains('找回')),
        out.entries.map((e) => e.stem).join(' | '));
    final e = out.entries.first;
    final n = _ints(e.stem);
    ck('购物衍生题答案 = 付的钱 − 单价 × 数量',
        e.answerValue == (n[2] - n[1] * n[0]),
        '${e.stem} → ${e.answer}（期望 ${n[2] - n[1] * n[0]}）');
    ck('购物衍生题答案带单位', e.answer.endsWith('元'), e.answer);
  }

  // ── 8) 去重仍然有效：同一道原题的两次衍生不会堆两份 ──
  {
    final src = byKind['sub']!.first;
    final a = await DeriveAgent(seed: 5).deriveAll([src]);
    final b = await DeriveAgent(seed: 5).deriveAll([src]);
    final dir = Directory.systemTemp.createTempSync('mc_shape_');
    final bank = QuestionBank(file: File('${dir.path}/bank.json'));
    await bank.load();
    final fresh1 = await bank.addAll(a.entries);
    final fresh2 = await bank.addAll(b.entries);
    ck('同样种子的衍生题题库只收一份',
        fresh1 == DeriveAgent.perQuestion && fresh2 == 0,
        '第一次 $fresh1 第二次 $fresh2');
    dir.deleteSync(recursive: true);
  }

  // ── 9) 变体闯关那三条路：严格 → 宽松 → 按题干认 → 年级轮换兜底 ──
  //
  // 2026-10-17 家长反馈："错题本变体闯关都是固定的分数相加减。"
  // 根因是 23 个题型里一半在 variantKindFor 里没映射，全落到年级兜底，
  // 而五年级兜底写死 fracAddSub。这里把新加的两条路钉住。
  {
    // ① 按题干认：面积/周长必须分开（这是 M12 修掉的同一个病）
    final area = variantRecipeByStem('一个长方形长 8 厘米宽 5 厘米，面积是多少？');
    final perim = variantRecipeByStem('一个长方形长 8 厘米宽 5 厘米，周长是多少？');
    ck('题干认：长方形面积 → rectArea',
        area?.kind == VariantKind.rectAreaPerimeter && area?.shape == VariantShape.rectArea,
        '${area?.kind}/${area?.shape}');
    ck('题干认：长方形周长 → rectPerim',
        perim?.kind == VariantKind.rectAreaPerimeter && perim?.shape == VariantShape.rectPerim,
        '${perim?.kind}/${perim?.shape}');

    // ② 倍数题分一步/两步
    final twoStep = variantRecipeByStem('故事书有 3 包，科技书是故事书的 2 倍，两种书一共多少本？');
    final oneStep = variantRecipeByStem('故事书有 3 包，科技书是故事书的 2 倍，科技书有多少本？');
    ck('题干认：倍数问"一共" → mulThenAdd',
        twoStep?.shape == VariantShape.mulThenAdd, '${twoStep?.shape}');
    ck('题干认：倍数问"多少本" → timesOneStep',
        oneStep?.shape == VariantShape.timesOneStep, '${oneStep?.shape}');

    // ③ 找零、有余数除法、单位换算
    ck('题干认：找零 → wordPrice/mulThenSub',
        variantRecipeByStem('买 5 支铅笔，每支 6 元，付给售货员 50 元，应找回多少元？')?.shape ==
            VariantShape.mulThenSub);
    ck('题干认：平均分有余数 → divRem',
        variantRecipeByStem('把 17 个苹果平均分给 3 个小朋友，每人分几个，还剩几个？')?.shape ==
            VariantShape.divRem);
    ck('题干认：两类单位连着出现 → unitConv',
        variantRecipeByStem('一根绳子长 2 米，是多少厘米？')?.kind == VariantKind.unitConvert);

    // ④ 一条纯算式（拍照判卷收进来的口算题，kind 常常是空的）
    final bare = variantRecipeByStem('731 − 463 =');
    ck('题干认：裸减法算式 → addSub3/sub',
        bare?.kind == VariantKind.addSub3 && bare?.shape == VariantShape.add,
        '${bare?.kind}/${bare?.shape}');

    // ⑤ 本地没有同算法模板的，认输（交给模型），不出不相干的题
    for (final s in const [
      '一个梯形的上底是 3 厘米，下底是 5 厘米，高是 4 厘米，面积是多少？',
      '一条 100 米的小路一侧植树，两端都栽，每隔 5 米栽一棵，一共要栽多少棵？',
      '一个正方体的棱长是 5 厘米，表面积是多少？',
      '一堆煤，第一天运走 1/3，第二天运走 1/4，一共运走几分之几？',
    ]) {
      ck('题干认不出同算法模板 → 返回 null（交模型）: ${s.length > 12 ? s.substring(0, 12) : s}…',
          variantRecipeByStem(s) == null);
    }

    // ⑥ 年级兜底按组轮换，不再万年一个
    final kinds = [for (var i = 0; i < 5; i++) fallbackVariantKind(5, salt: i)];
    ck('五年级兜底在一组里轮换（5 次至少 3 种）',
        kinds.toSet().length >= 3, kinds.map((k) => k.name).join(','));
    ck('salt=0 时兜底行为和以前一致（五年级 = 分数加减）',
        fallbackVariantKind(5) == VariantKind.fracAddSub);
    ck('兜底不会跨年级乱跳（一年级永远在低年级组里）',
        const [VariantKind.addSub3, VariantKind.mul2x1]
            .contains(fallbackVariantKind(1, salt: 3)));
  }

  print('\n共派生 $derivedTotal 道衍生题做过结构校验');
  print('$_pass 通过 / $_fail 失败');
  exitCode = _fail == 0 ? 0 : 1;
}
