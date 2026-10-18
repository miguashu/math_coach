/// 题型 → 变体模板的映射。
///
/// 刻意分三层，**用途不同，不要合并**：
///
/// - [variantKindFor]：**宽松映射（只看题型名）**。给「变体闯关」按钮用 ——
///   那里是用户主动点的，按钮点下去必须有反应，所以宁可出同年级的常规题。
///   认不出题型时由 [fallbackVariantKind] 按年级兜底。
///
/// - [localRecipeFor]：**严格映射（题型 + 算法结构）**。给「错题衍生题」用 ——
///   衍生题是挂在一道具体错题下面的，家长看到的是「这道题不会 → 给你几道同类的」，
///   这时候出一道**另一个算法**的题比不出题更糟：孩子连对两次，题库里就多一个
///   假的"已掌握"。所以它连 `rect` 是面积还是周长、`timesAs` 是一步还是两步
///   都要问清楚，问不清就返回 null 交给模型。
///
/// - [fallbackVariantKind]：**年级兜底**，只给变体闯关用，衍生题绝不走这条 ——
///   兜底意味着"不知道原题是什么"，而衍生题的前提正是"知道原题是什么"。
///   兜底按年级在一组里**轮换**（2026-10-17 修：以前五年级写死分数加减，
///   家长看到的就是"变体闯关都是固定的分数相加减"）。
///
/// - [variantRecipeByStem]：**按题干认**，同样只给变体闯关用。错题本里的题
///   不一定带得上题型名（AI 出的、拍照判卷收的、老存档），这时先读题干关键词，
///   读不出来才轮到年级兜底。
library;

import 'generator.dart';

/// 严格映射：这个题型的题，本地有真正同类的变体模板吗？
///
/// 判断标准只有一条：**孩子做这道衍生题时，用的算法和原题一样吗？**
/// 名字听起来相关不算 —— 所以这几类刻意**不**映射：
///
/// | 题型 | 为什么不映射 |
/// |---|---|
/// | `mixOps` 混合运算 | 考的是**运算顺序**，本地减加模板只出单步算式，练不到这个考点 |
/// | `interval` 植树/间隔 | 考的是**段数与点数的关系**，四则模板练不到 |
/// | `average` 平均数 | 一条式子里既有乘也有除（总数÷份数），模板覆盖不了 |
/// | `trapezoid` 梯形面积 | 公式是 `(a+b)×h÷2`，和长方形/三角形模板都不同 |
/// | `cylinder`/`cuboid`/`cuboidSurface`/`cubeNet` 立体 | 一维长度与三维体积的换算关系，模板里没有 |
///
/// 这些交给模型按原题干出（见 `lib/ai/derive.dart`），
/// 或者没配 key 时如实告诉家长"这道题暂时造不出衍生题"。
VariantKind? variantKindFor(String quizKind) => switch (quizKind) {
      'add' || 'sub' => VariantKind.addSub3,
      'mul' || 'timesAs' => VariantKind.mul2x1,
      'divRem' => VariantKind.divRemainder,
      'fractionOf' => VariantKind.fracAddSub,
      // 长方形 / 格点图形 / 组合图形 / 平行四边形：都是"两个长度相乘得面积"
      'rect' || 'lattice' || 'composite' || 'parallelogram' =>
        VariantKind.rectAreaPerimeter,
      'triangle' => VariantKind.triangleArea,
      'circleArea' || 'circlePerim' => VariantKind.circleArea,
      'unitConv' => VariantKind.unitConvert,
      // 单价×数量：和钱有关的乘法应用题
      'shopping' => VariantKind.wordPrice,
      _ => null,
    };

// ════════════════ 衍生题专用：带结构的严格映射 ════════════════

/// 一道错题的本地衍生处方：用哪个模板 + **必须保持哪种算法结构**。
class LocalRecipe {
  final VariantKind kind;
  final VariantShape shape;
  const LocalRecipe(this.kind, this.shape);

  @override
  String toString() => '${kind.label} / ${shape.name}';
}

/// 衍生题用的严格映射。**认不出结构就返回 null**（交给模型），不许猜。
///
/// 与 [variantKindFor] 的区别（**刻意不合并**）：
///
/// - [variantKindFor] 只看题型名，给「变体闯关」用 —— 那是用户自己点的按钮，
///   按钮点下去必须出题，出个同年级的常规题是可以接受的（甚至兜底到
///   [fallbackVariantKind] 直接忽略原题型）。
/// - [localRecipeFor] 还要看**结构**，给「错题衍生题」用 —— 衍生题挂在
///   一道具体错题下面，说好是"同类的"，出成别的算法就是骗人。
///
/// 结构从哪来：本地题库的题干是模板生成的（见 `lib/quiz/generator.dart`），
/// 每一种结构都有固定的问法，所以**从题干里就能读出结构**。
/// 反过来，题干读不出结构（模型出的应用题、题型对不上）就返回 null，
/// 这条题走去问模型，而不是在本地硬凑一道。
///
/// 已知边界：这是"按问法认结构"，不是形式化证明。所以只覆盖本地出题器
/// 真实产出过的问法；遇到没见过的问法一律返回 null —— 保守但不会错。
LocalRecipe? localRecipeFor({
  required String quizKind,
  required String stem,
}) {
  VariantShape? shape;
  VariantKind? kind;

  switch (quizKind) {
    case 'add':
      kind = VariantKind.addSub3;
      shape = VariantShape.add;
    case 'sub':
      kind = VariantKind.addSub3;
      shape = VariantShape.sub;
    case 'mul':
      // 「用竖式算一算：a × b =」：形是竖式、算法是乘法。
      // 本地模板出的是乘法应用题（数字换了、情境换了），算法一样。
      kind = VariantKind.mul2x1;
      shape = VariantShape.mul;
    case 'timesAs':
      // 「…科技书是故事书的 k 倍，**两种书一共**多少本」= 先乘后加；
      // 「…科技书有多少本」= 一步乘法。差一步就是两个考点。
      if (!stem.contains('倍')) return null;
      kind = VariantKind.mul2x1;
      shape = stem.contains('一共')
          ? VariantShape.mulThenAdd
          : VariantShape.timesOneStep;
    case 'divRem':
      // 本地出题器只有一种形态：「用竖式算一算：a ÷ b =」（商……余数）。
      // 出题时有闸门保证余数不为 0，所以题型本身就已经说明了结构。
      // 衍生题出成"平均分给几个小朋友，每人分几个还剩几个"（应用题形态）——
      // 算式还是那个算式（商 + 余数），换个说法不算换算法。
      kind = VariantKind.divRemainder;
      shape = VariantShape.divRem;
    case 'rect':
      // 面积是 长×宽，周长是 (长+宽)×2 —— 同一个图形两个公式，必须分清
      kind = VariantKind.rectAreaPerimeter;
      if (stem.contains('面积')) {
        shape = VariantShape.rectArea;
      } else if (stem.contains('周长')) {
        shape = VariantShape.rectPerim;
      } else {
        return null;
      }
    case 'triangle':
      if (!stem.contains('面积')) return null;
      kind = VariantKind.triangleArea;
      shape = VariantShape.triArea;
    case 'circleArea':
      if (!stem.contains('面积')) return null;
      kind = VariantKind.circleArea;
      shape = VariantShape.circleArea;
    case 'unitConv':
      kind = VariantKind.unitConvert;
      shape = VariantShape.unitConv;
    case 'shopping':
      // 本地只出过"应找回多少元"这种两步题；一步的"求总价"另说
      if (!stem.contains('找回')) return null;
      kind = VariantKind.wordPrice;
      shape = VariantShape.mulThenSub;
    default:
      return null;
  }

  if (!VariantGenerator.shapeFits(kind, shape)) return null;
  return LocalRecipe(kind, shape);
}

/// 年级兜底：模型/本地都没给出题型的题，按年级给一个"这个年级一定会考"的模板。
///
/// 2026-10-17 家长反馈："错题本变体闯关都是固定的分数相加减。"
/// 根因：23 个题型里有一半在 [variantKindFor] 里没有映射（混合运算、植树、
/// 平均数、梯形、各种立体图形……），错题本里这些题一多，就全落到年级兜底，
/// 而五年级的兜底写死是 `fracAddSub` —— 于是每次点开都是分数加减。
///
/// 两个修法一起上：
/// ① 兜底**按年级轮换**（同一组里转着来，不是万年一个）；
/// ② 兜底之前先按题干认一遍（见 [variantRecipeByStem]），能认出来的根本不轮到兜底。
///
/// [salt] 由调用方给（比如这是第几道错题、第几轮闯关）——
/// 传 0 时行为和以前完全一致，老调用方不用改。
VariantKind fallbackVariantKind(int grade, {int salt = 0}) {
  final list = switch (grade) {
    1 => const [VariantKind.addSub3, VariantKind.mul2x1],
    2 => const [VariantKind.addSub3, VariantKind.mul2x1, VariantKind.divRemainder],
    3 => const [
        VariantKind.mul2x1,
        VariantKind.addSub3,
        VariantKind.rectAreaPerimeter,
        VariantKind.unitConvert,
      ],
    4 => const [
        VariantKind.divRemainder,
        VariantKind.mul2x1,
        VariantKind.rectAreaPerimeter,
        VariantKind.addSub3,
      ],
    5 => const [
        VariantKind.fracAddSub,
        VariantKind.mul2x1,
        VariantKind.rectAreaPerimeter,
        VariantKind.triangleArea,
        VariantKind.divRemainder,
      ],
    _ => const [
        VariantKind.circleArea,
        VariantKind.mul2x1,
        VariantKind.divRemainder,
        VariantKind.rectAreaPerimeter,
      ],
  };
  return list[salt.abs() % list.length];
}

// ════════════════ 第三条路：按题干认（比题型名宽，比兜底严）════════════════

/// 变体闯关专用的宽松处方：**题干里读得出什么就出什么**。
///
/// 为什么需要它：错题本里的题不一定带得上题型名 —— AI 出的题、
/// 拍照判卷收进来的题、老版本存档，`kind` 可能是空或者不认识。
/// 这时 [variantKindFor] 返回 null，以前直接按年级兜底（见上面的反馈）。
/// 但题干里其实留着线索：本地题库的问法是固定的，认关键词就够。
///
/// 返回的 shape 可能是 null —— 那是"只知道题型、不知道结构"，
/// 让生成器自己按题型的老行为来（变体闯关是用户主动点的按钮，
/// 不要求和衍生题那样严格同结构；但**认得出的结构仍然带上**，
/// 免得面积题出成周长题）。
///
/// 认不出来返回 null，由调用方决定兜底还是问模型。
/// 刻意不映射的（本地没有同算法模板，出了就是骗人）：
/// 梯形、平行四边形、组合/格点图形、立体图形与展开图、圆柱、混合运算、
/// 植树/间隔、平均数、求几分之几 —— 这些走模型那一路。
({VariantKind kind, VariantShape? shape})? variantRecipeByStem(
  String stem, {
  String? kpPath,
}) {
  final s = '$stem ${kpPath ?? ''}';

  // 一条纯算式（拍照判卷收进来的口算/竖式题，kind 常常是空的）
  // 注意字符类里的 "-" 必须转义：否则 "−-×" 会被当成字符范围，直接抛
  // FormatException（Range out of order）—— 这个坑踩过一次。
  final bare = RegExp(r'^\s*(\d+)\s*([+\-−×x*÷/])\s*(\d+)\s*=').firstMatch(stem);
  if (bare != null) {
    final op = bare.group(2)!;
    if (op == '+' || op == '−' || op == '-') {
      return (kind: VariantKind.addSub3, shape: VariantShape.add);
    }
    if (op == '×' || op == 'x' || op == '*') {
      return (kind: VariantKind.mul2x1, shape: VariantShape.mul);
    }
    return (kind: VariantKind.divRemainder, shape: VariantShape.divRem);
  }

  // 本地没有同算法模板的，直接认输 —— 宁可问模型，不出不相干的题
  if (s.contains('梯形') ||
      s.contains('平行四边形') ||
      s.contains('组合') ||
      s.contains('格点') ||
      s.contains('立体') ||
      s.contains('展开') ||
      s.contains('圆柱') ||
      s.contains('长方体') ||
      s.contains('正方体') ||
      s.contains('圆锥') ||
      s.contains('混合运算') ||
      s.contains('植树') ||
      s.contains('间隔') ||
      s.contains('平均数') ||
      s.contains('几分之几')) {
    return null;
  }

  if (s.contains('周长')) {
    return (kind: VariantKind.rectAreaPerimeter, shape: VariantShape.rectPerim);
  }
  if (s.contains('面积')) {
    if (s.contains('三角')) {
      return (kind: VariantKind.triangleArea, shape: VariantShape.triArea);
    }
    if (s.contains('圆')) {
      return (kind: VariantKind.circleArea, shape: VariantShape.circleArea);
    }
    if (s.contains('长方') || s.contains('正方') || s.contains('矩形')) {
      return (kind: VariantKind.rectAreaPerimeter, shape: VariantShape.rectArea);
    }
    return null; // 别的图形的面积，本地模板对不上
  }
  if (s.contains('倍')) {
    return (
      kind: VariantKind.mul2x1,
      shape: s.contains('一共') ? VariantShape.mulThenAdd : VariantShape.timesOneStep
    );
  }
  if (s.contains('找回') || s.contains('付给') || s.contains('售货员')) {
    return (kind: VariantKind.wordPrice, shape: VariantShape.mulThenSub);
  }
  if ((s.contains('单价') || s.contains('每支') || s.contains('每个')) && s.contains('一共')) {
    return (kind: VariantKind.wordPrice, shape: VariantShape.timesOneStep);
  }
  if ((s.contains('除') || s.contains('平均')) && (s.contains('余') || s.contains('还剩'))) {
    return (kind: VariantKind.divRemainder, shape: VariantShape.divRem);
  }
  if (s.contains('分数') || s.contains('同分母')) {
    return (kind: VariantKind.fracAddSub, shape: null);
  }
  // 单位换算：两类单位连着出现
  final units = ['米', '厘米', '吨', '千克', '克', '时', '分', '元', '角', '千米', '毫米'];
  var hits = 0;
  for (final u in units) {
    if (s.contains(u)) hits++;
  }
  if (hits >= 2) {
    return (kind: VariantKind.unitConvert, shape: VariantShape.unitConv);
  }
  return null;
}
