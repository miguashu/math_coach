import 'dart:math' as math;

import '../core/rational.dart';

/// 变体生成器 + 正确性闸门。
///
/// 铁律（来自方案 P1 反对六）：
///   「数字在本地随机并做边界校验；答案本地算；模型仅负责换情境、换问法的自然语言部分。」
/// 这样才不会出现"三边 3、4、8 不成三角形""应用题除不尽""周长改了面积没改"这类退化题。

enum VariantKind {
  mul2x1('两位数乘一位数（进位）', 'MA-G3-S1-NA-04-02'),
  addSub3('万以内加减法', 'MA-G3-S1-NA-02-01'),
  divRemainder('有余数的除法', 'MA-G2-S2-NA-03-01'),
  fracAddSub('同分母分数加减', 'MA-G5-S2-NA-03-01'),
  rectAreaPerimeter('长方形面积与周长', 'MA-G3-S2-GS-02-02'),
  triangleArea('三角形的面积', 'MA-G5-S1-GS-02-02'),
  circleArea('圆的面积', 'MA-G6-S1-GS-02-02'),
  unitConvert('单位换算', 'MA-G3-S1-NA-03-01'),
  wordPrice('单价×数量应用题', 'MA-G3-S1-NA-04-03');

  const VariantKind(this.label, this.defaultCode);
  final String label;
  final String defaultCode;
}

/// 源题的「算法结构」—— 衍生题必须与源题**同结构**。
///
/// 为什么光看题型不够：一个题型里往往藏着几种不同的算法。
///
/// | 题型 | 藏着的结构 |
/// |---|---|
/// | `rect` | 面积 `长×宽` / 周长 `(长+宽)×2` |
/// | `timesAs` | 求几倍（一步乘）/ 一共多少（先乘后加） |
/// | `shopping` | 求总价（一步乘）/ 找零（先乘后减） |
/// | `addSub3` 对应 | 加法 / 减法 |
///
/// 只按题型映射就会出这样的事：**面积错题衍生出周长题、减法错题
/// 衍生出加法题**。孩子把 `573+652` 连对两次并不能说明 `731−463` 会了，
/// 却会在题库里留下一个假的「已掌握」—— 比不出题更糟。
///
/// 所以本地衍生这条路上，结构必须由调用方显式带过来
/// （见 `variant/mapping.dart` 的 `localRecipeFor`）：
/// **判断不出结构就退回模型，不许猜。**
enum VariantShape {
  add, // a + b
  sub, // a − b
  mul, // a × b（笔算乘法）
  timesOneStep, // 求一个数的几倍是多少：a × b
  mulThenAdd, // 求几倍之后求和：a + a × b
  mulThenSub, // 找零：付的钱 − 单价 × 数量
  divRem, // 有余数除法
  rectArea, // 长 × 宽
  rectPerim, // （长 + 宽）× 2
  triArea, // 底 × 高 ÷ 2
  circleArea, // πr²
  unitConv, // 单位换算
}

/// 一道变体题（数字已定、答案已本地算出）。
class Variant {
  final VariantKind kind;

  /// 生成时被要求保持的算法结构。null = 没约束（「变体闯关」那种
  /// 用户主动点的场景，只要出得来题就行）。
  final VariantShape? shape;

  final Map<String, num> params;
  final String stem;
  final Rational answer;
  final String answerUnit;
  final List<String> changeDims;
  final String? knowledgeCode;

  /// 人读的答案（可选）。默认用 "$answer$answerUnit"。
  ///
  /// 有余数除法必须给这个：题问"每人分几个、还剩几个"，
  /// 答案是"4……4"，拼不出也拆不得 —— 塞进 unit 括号里既难看又难判分。
  final String? answerText;

  const Variant({
    required this.kind,
    required this.params,
    required this.stem,
    required this.answer,
    required this.answerUnit,
    required this.changeDims,
    this.shape,
    this.knowledgeCode,
    this.answerText,
  });

  String get displayAnswer =>
      answerText ?? (answerUnit.isEmpty ? '$answer' : '$answer$answerUnit');

  /// 换数字后重新生成题干（情境/问法保持不变）。
  String get displayStem => stem;
}

/// 闸门判定结果。
class GateResult {
  final bool passed;
  final List<String> violations;

  const GateResult(this.passed, this.violations);

  static const ok = GateResult(true, []);
}

class VariantGenerator {
  final math.Random rnd;

  VariantGenerator({int? seed}) : rnd = math.Random(seed);

  /// 结构能不能落在模板上。**这是本地衍生路的守门人**：
  /// 带了个模板表达不了的结构（比如要求"减法"却映射到了加减模板之外），
  /// 就直接返回 null 交给模型，而不是硬出一道路子不对的题。
  static bool shapeFits(VariantKind kind, VariantShape? shape) {
    if (shape == null) return true; // 没约束 = 什么都行
    return switch (kind) {
      VariantKind.addSub3 =>
        shape == VariantShape.add || shape == VariantShape.sub,
      VariantKind.mul2x1 => shape == VariantShape.mul ||
          shape == VariantShape.timesOneStep ||
          shape == VariantShape.mulThenAdd,
      VariantKind.wordPrice =>
        shape == VariantShape.mulThenSub || shape == VariantShape.timesOneStep,
      VariantKind.divRemainder => shape == VariantShape.divRem,
      VariantKind.rectAreaPerimeter =>
        shape == VariantShape.rectArea || shape == VariantShape.rectPerim,
      VariantKind.triangleArea => shape == VariantShape.triArea,
      VariantKind.circleArea => shape == VariantShape.circleArea,
      VariantKind.unitConvert => shape == VariantShape.unitConv,
      VariantKind.fracAddSub => false, // 衍生题不用它：分数加减和"求几分之几"是两种算法
    };
  }

  /// 生成一道变体；不合法就重抽，抽不到就换一个更保守的参数区间。
  /// 最多重试 60 次，仍失败返回 null（调用方应降级到"原题重练"而不是硬塞一道错题）。
  Variant? generate(VariantKind kind, {int? grade, VariantShape? shape}) {
    if (!shapeFits(kind, shape)) return null;
    for (var i = 0; i < 60; i++) {
      final p = _randomParams(kind, grade, shape);
      final v = _build(kind, p, grade, shape);
      if (v == null) continue;
      final gate = VariantGate.check(v);
      if (gate.passed) return v;
    }
    return null;
  }

  /// 批量生成，自动去重（同一组数字不重复出现）。
  List<Variant> generateMany(VariantKind kind, int count,
      {int? grade, VariantShape? shape}) {
    final out = <Variant>[];
    final seen = <String>{};
    for (var i = 0; i < count * 20 && out.length < count; i++) {
      final v = generate(kind, grade: grade, shape: shape);
      if (v == null) continue;
      final sig = v.params.entries.map((e) => '${e.key}=${e.value}').join('|');
      if (seen.contains(sig)) continue;
      seen.add(sig);
      out.add(v);
    }
    return out;
  }

  Map<String, num> _randomParams(VariantKind kind, int? grade, VariantShape? s) {
    int ri(int min, int max) => min + rnd.nextInt(max - min + 1);

    switch (kind) {
      case VariantKind.mul2x1:
        // 倍数题：照着课本题的规模取数（低年级 3~15，四年级以上 3~40）
        if (s == VariantShape.timesOneStep || s == VariantShape.mulThenAdd) {
          return {'a': ri(3, (grade ?? 3) >= 4 ? 40 : 15), 'b': ri(2, 6)};
        }
        return {'a': ri(12, 39), 'b': ri(3, 9)};
      case VariantKind.addSub3:
        final a = ri(120, 899);
        final b = ri(110, 899);
        if (s == VariantShape.add) return {'a': a, 'b': b, 'op': 1};
        if (s == VariantShape.sub) {
          // 结构要求减法：先把大小理好，别靠 60 次重抽碰运气
          return a >= b
              ? {'a': a, 'b': b, 'op': -1}
              : {'a': b, 'b': a, 'op': -1};
        }
        return {'a': a, 'b': b, 'op': rnd.nextBool() ? 1 : -1};
      case VariantKind.divRemainder:
        return {'a': ri(20, 99), 'b': ri(3, 9)};
      case VariantKind.fracAddSub:
        final den = ri(3, 9);
        final n1 = ri(1, den - 1);
        final n2 = ri(1, den - 1);
        return {'den': den, 'n1': n1, 'n2': n2, 'op': 1}; // 只出加法，保证不超 1
      case VariantKind.rectAreaPerimeter:
        return {'w': ri(3, 12), 'h': ri(2, 9)};
      case VariantKind.triangleArea:
        return {'base': ri(4, 14), 'height': ri(3, 11)};
      case VariantKind.circleArea:
        return {'r': ri(2, 9)};
      case VariantKind.unitConvert:
        final units = [
          ('米', '厘米', 100),
          ('千米', '米', 1000),
          ('吨', '千克', 1000),
          ('千克', '克', 1000),
        ];
        final u = units[rnd.nextInt(units.length)];
        return {'value': ri(2, 24), 'factor': u.$3, 'from': 0, 'to': 0, 'unitIdx': units.indexOf(u)};
      case VariantKind.wordPrice:
        if (s == VariantShape.mulThenSub) {
          final units = [2, 3, 4, 5, 6, 8, 9];
          return {
            'price': units[rnd.nextInt(units.length)],
            'count': ri(2, (grade ?? 3) >= 3 ? 8 : 5),
          };
        }
        return {'price': ri(3, 28), 'count': ri(3, 12)};
    }
  }

  Variant? _build(VariantKind kind, Map<String, num> p, int? grade,
      VariantShape? shape) {
    final a = (p['a'] ?? 0).toInt();
    final b = (p['b'] ?? 0).toInt();

    switch (kind) {
      case VariantKind.mul2x1:
        if (shape == VariantShape.timesOneStep) {
          // 求一个数的几倍是多少 —— 一步乘法
          return Variant(
            kind: kind,
            shape: shape,
            params: p,
            stem: '图书角有故事书 $a 本，科技书的本数是故事书的 $b 倍，科技书有多少本？',
            answer: Rational.fromBig(BigInt.from(a * b)),
            answerUnit: '本',
            changeDims: const ['数字', '情境', '单位'],
            knowledgeCode: kind.defaultCode,
          );
        }
        if (shape == VariantShape.mulThenAdd) {
          // 求几倍之后还要合起来 —— 两步，最后一步最容易漏
          return Variant(
            kind: kind,
            shape: shape,
            params: p,
            stem: '图书角有故事书 $a 本，科技书的本数是故事书的 $b 倍，两种书一共多少本？',
            answer: Rational.fromBig(BigInt.from(a + a * b)),
            answerUnit: '本',
            changeDims: const ['数字', '情境', '单位'],
            knowledgeCode: kind.defaultCode,
          );
        }
        // 必须是"进位"乘法：个位相乘满十
        if ((a % 10) * b < 10) return null;
        return Variant(
          kind: kind,
          shape: shape,
          params: p,
          stem: '每盒有 $a 支彩笔，买 $b 盒，一共有多少支？',
          answer: Rational.fromBig(BigInt.from(a * b)),
          answerUnit: '支',
          changeDims: const ['数字', '情境', '单位'],
          knowledgeCode: kind.defaultCode,
        );

      case VariantKind.addSub3:
        final op = (p['op'] ?? 1).toInt();
        if (op > 0) {
          return Variant(
            kind: kind,
            shape: shape,
            params: p,
            stem: '$a + $b = ？',
            answer: Rational.fromBig(BigInt.from(a + b)),
            answerUnit: '',
            changeDims: const ['数字'],
            knowledgeCode: kind.defaultCode,
          );
        }
        if (a < b) return null; // 不出现负数
        return Variant(
          kind: kind,
          shape: shape,
          params: p,
          stem: '$a − $b = ？',
          answer: Rational.fromBig(BigInt.from(a - b)),
          answerUnit: '',
          changeDims: const ['数字'],
          knowledgeCode: kind.defaultCode,
        );

      case VariantKind.divRemainder:
        if (b == 0) return null;
        if (a % b == 0) return null; // 必须"有余数"，否则就不是这个考点了
        return Variant(
          kind: kind,
          shape: shape,
          params: p,
          stem: '把 $a 个苹果平均分给 $b 个小朋友，每人分几个，还剩几个？',
          answer: Rational.fromBig(BigInt.from(a ~/ b)),
          answerUnit: '',
          answerText: '${a ~/ b}……${a % b}',
          changeDims: const ['数字', '情境'],
          knowledgeCode: kind.defaultCode,
        );

      case VariantKind.fracAddSub:
        final den = (p['den'] ?? 1).toInt();
        final n1 = (p['n1'] ?? 0).toInt();
        final n2 = (p['n2'] ?? 0).toInt();
        if (n1 + n2 > den) return null; // 小学阶段不出现假分数结果
        return Variant(
          kind: kind,
          shape: shape,
          params: p,
          stem: '$n1/$den + $n2/$den = ？',
          answer: Rational.fromBig(BigInt.from(n1 + n2), BigInt.from(den)),
          answerUnit: '',
          changeDims: const ['数字'],
          knowledgeCode: kind.defaultCode,
        );

      case VariantKind.rectAreaPerimeter:
        final w = (p['w'] ?? 0).toInt();
        final h = (p['h'] ?? 0).toInt();
        // 结构说了算：源题问面积就只出面积，问周长就只出周长。
        // 只有"没约束"（变体闯关）时才随机换问法 —— 那不叫"同类题"，
        // 叫"同一知识点下的另一道题"，是用户主动点的，可以接受。
        final wantArea = switch (shape) {
          VariantShape.rectArea => true,
          VariantShape.rectPerim => false,
          _ => rnd.nextBool(),
        };
        return Variant(
          kind: kind,
          shape: shape,
          params: {...p, 'ask': wantArea ? 0 : 1},
          stem: wantArea
              ? '一个长方形，长 $w 厘米，宽 $h 厘米，它的面积是多少？'
              : '一个长方形，长 $w 厘米，宽 $h 厘米，它的周长是多少？',
          answer: wantArea
              ? Rational.fromBig(BigInt.from(w * h))
              : Rational.fromBig(BigInt.from(2 * (w + h))),
          answerUnit: wantArea ? '平方厘米' : '厘米',
          changeDims: wantArea
              ? const ['数字']
              : const ['数字', '问法'],
          knowledgeCode: kind.defaultCode,
        );

      case VariantKind.triangleArea:
        final base = (p['base'] ?? 0).toInt();
        final height = (p['height'] ?? 0).toInt();
        // 面积必须是整数或半整数：base*height 为偶数时才是整数，小学阶段优先整数
        if ((base * height) % 2 != 0) return null;
        return Variant(
          kind: kind,
          shape: shape,
          params: p,
          stem: '一个三角形的底是 $base 厘米，高是 $height 厘米，面积是多少？',
          answer: Rational.fromBig(BigInt.from(base * height), BigInt.from(2)),
          answerUnit: '平方厘米',
          changeDims: const ['数字', '情境'],
          knowledgeCode: kind.defaultCode,
        );

      case VariantKind.circleArea:
        final r = (p['r'] ?? 0).toInt();
        return Variant(
          kind: kind,
          shape: shape,
          params: p,
          stem: '一个圆的半径是 $r 厘米，它的面积是多少？（π 取 3.14）',
          answer: Rational.fromBig(BigInt.from(314 * r * r), BigInt.from(100)),
          answerUnit: '平方厘米',
          changeDims: const ['数字'],
          knowledgeCode: kind.defaultCode,
        );

      case VariantKind.unitConvert:
        final idx = (p['unitIdx'] ?? 0).toInt();
        final units = [
          ('米', '厘米', 100),
          ('千米', '米', 1000),
          ('吨', '千克', 1000),
          ('千克', '克', 1000),
        ];
        if (idx < 0 || idx >= units.length) return null;
        final u = units[idx];
        final value = (p['value'] ?? 0).toInt();
        return Variant(
          kind: kind,
          shape: shape,
          params: p,
          stem: '$value ${u.$1} = （ ）${u.$2}',
          answer: Rational.fromBig(BigInt.from(value * u.$3)),
          answerUnit: u.$2,
          changeDims: const ['数字', '单位'],
          knowledgeCode: kind.defaultCode,
        );

      case VariantKind.wordPrice:
        final price = (p['price'] ?? 0).toInt();
        final count = (p['count'] ?? 0).toInt();
        if (shape == VariantShape.mulThenSub) {
          // 找零：先算花掉多少，再拿付的钱去减 —— 两步。
          // 源题「应找回多少元」是两步，给个一步的"求总价"就是换了算法。
          // 付的钱取"比总价大的整十元"，和课本上"给一张整钱"一致。
          final total = price * count;
          final paid = ((total ~/ 10) + 2) * 10;
          return Variant(
            kind: kind,
            shape: shape,
            params: {...p, 'paid': paid},
            stem: '小明买了 $count 支铅笔，每支 $price 元，'
                '付给售货员 $paid 元，应找回多少元？',
            answer: Rational.fromBig(BigInt.from(paid - total)),
            answerUnit: '元',
            changeDims: const ['数字', '情境'],
            knowledgeCode: kind.defaultCode,
          );
        }
        return Variant(
          kind: kind,
          shape: shape,
          params: p,
          stem: '一支钢笔 $price 元，买 $count 支要花多少元？',
          answer: Rational.fromBig(BigInt.from(price * count)),
          answerUnit: '元',
          changeDims: const ['数字', '情境', '单位'],
          knowledgeCode: kind.defaultCode,
        );
    }
  }
}

/// 正确性闸门：生成后必须过这一关，不过就丢弃重生成。
class VariantGate {
  static GateResult check(Variant v) {
    final bad = <String>[];

    // 1) 答案必须存在且有限
    if (v.answer.d == BigInt.zero) {
      bad.add('答案分母为 0');
      return GateResult(false, bad);
    }
    if (v.answer.isNegative) {
      bad.add('小学阶段不应出现负数答案：${v.answer}');
    }

    // 2) 按题型做专项校验
    switch (v.kind) {
      case VariantKind.mul2x1:
        final a = (v.params['a'] ?? 0).toInt();
        final b = (v.params['b'] ?? 0).toInt();
        if (v.shape == VariantShape.timesOneStep ||
            v.shape == VariantShape.mulThenAdd) {
          // 倍数题：这里的考点是"倍"，不是进位笔算，所以不要求进位
          if (b < 2 || b > 9) bad.add('倍数必须是 2~9：$b');
          if (a < 2 || a > 99) bad.add('一倍量必须在 2~99：$a');
          final target = a * b;
          final expect =
              v.shape == VariantShape.mulThenAdd ? a + target : target;
          if (v.answer != Rational.fromBig(BigInt.from(expect))) {
            bad.add('答案与本地计算不符');
          }
          if (expect > 999) bad.add('结果超出该年级常见范围：$expect');
          if (v.shape == VariantShape.mulThenAdd &&
              !v.stem.contains('一共')) {
            bad.add('两步倍数题必须问"一共"，否则容易只看一步');
          }
        } else {
          if (a < 10 || a > 99) bad.add('被乘数必须是两位数：$a');
          if (b < 2 || b > 9) bad.add('乘数必须是一位数且大于 1：$b');
          if ((a % 10) * b < 10) bad.add('不是进位乘法，考点不符');
          if (v.answer != Rational.fromBig(BigInt.from(a * b))) {
            bad.add('答案与本地计算不符');
          }
        }

      case VariantKind.addSub3:
        final a = (v.params['a'] ?? 0).toInt();
        final b = (v.params['b'] ?? 0).toInt();
        final op = (v.params['op'] ?? 1).toInt();
        if (op < 0 && a < b) bad.add('减法出现负数');
        // 结构是命令不是建议：要求减法就必须真是减法
        if (v.shape == VariantShape.sub && op > 0) bad.add('结构要求减法，却出了加法');
        if (v.shape == VariantShape.add && op < 0) bad.add('结构要求加法，却出了减法');
        final expect = op > 0 ? a + b : a - b;
        if (v.answer != Rational.fromBig(BigInt.from(expect))) bad.add('答案与本地计算不符');
        if (expect > 10000) bad.add('超出万以内范围');

      case VariantKind.divRemainder:
        final a = (v.params['a'] ?? 0).toInt();
        final b = (v.params['b'] ?? 0).toInt();
        if (b == 0) bad.add('除数为 0');
        if (a % b == 0) bad.add('没有余数，考点不符');
        if (a % b >= b) bad.add('余数大于等于除数');

      case VariantKind.fracAddSub:
        final den = (v.params['den'] ?? 0).toInt();
        final n1 = (v.params['n1'] ?? 0).toInt();
        final n2 = (v.params['n2'] ?? 0).toInt();
        if (den <= 1) bad.add('分母不合法');
        if (n1 <= 0 || n2 <= 0) bad.add('分子必须为正');
        if (n1 + n2 > den) bad.add('出现假分数结果');

      case VariantKind.rectAreaPerimeter:
        final w = (v.params['w'] ?? 0).toInt();
        final h = (v.params['h'] ?? 0).toInt();
        final ask = (v.params['ask'] ?? 0).toInt();
        if (w <= 0 || h <= 0) bad.add('长方形边长必须为正');
        if (w < h) bad.add('长应不小于宽，避免表述歧义');
        final expect = ask == 0
            ? Rational.fromBig(BigInt.from(w * h))
            : Rational.fromBig(BigInt.from(2 * (w + h)));
        if (v.answer != expect) bad.add('答案与本地计算不符');
        // 结构是命令不是建议：源题问面积就必须问面积
        if (v.shape == VariantShape.rectArea && ask != 0) {
          bad.add('结构要求面积，却出了周长');
        }
        if (v.shape == VariantShape.rectPerim && ask != 1) {
          bad.add('结构要求周长，却出了面积');
        }

      case VariantKind.triangleArea:
        final base = (v.params['base'] ?? 0).toInt();
        final height = (v.params['height'] ?? 0).toInt();
        if (base <= 0 || height <= 0) bad.add('三角形底高必须为正');
        // 与斜边无关的合法性：底高已足够定义三角形，但要保证答案是整数或 .5
        final twice = base * height;
        if (v.answer != Rational.fromBig(BigInt.from(twice), BigInt.from(2))) {
          bad.add('三角形面积与本地计算不符');
        }

      case VariantKind.circleArea:
        final r = (v.params['r'] ?? 0).toInt();
        if (r <= 0) bad.add('半径必须为正');
        final expect = Rational.fromBig(BigInt.from(314 * r * r), BigInt.from(100));
        if (v.answer != expect) bad.add('圆面积与本地计算不符');

      case VariantKind.unitConvert:
        if ((v.params['value'] ?? 0) <= 0) bad.add('换算值必须为正');

      case VariantKind.wordPrice:
        final price = (v.params['price'] ?? 0).toInt();
        final count = (v.params['count'] ?? 0).toInt();
        if (price <= 0 || count <= 0) bad.add('单价与数量必须为正');
        if (v.shape == VariantShape.mulThenSub) {
          final paid = (v.params['paid'] ?? 0).toInt();
          final total = price * count;
          if (paid <= total) bad.add('付的钱不够：$paid ≤ $total');
          if (paid % 10 != 0) bad.add('付的钱应是整十元：$paid');
          if (v.answer != Rational.fromBig(BigInt.from(paid - total))) {
            bad.add('找回的钱与本地计算不符');
          }
        } else {
          if (v.answer != Rational.fromBig(BigInt.from(price * count))) {
            bad.add('总价与本地计算不符');
          }
          if (price * count > 999) bad.add('总价过大，超出该年级常见范围');
        }
    }

    // 3) 答案必须"好看"：小学阶段不接受无限小数
    if (!v.answer.isInteger && !v.answer.hasFiniteDecimal && v.kind != VariantKind.fracAddSub) {
      bad.add('答案是无限小数，不适合小学阶段：${v.answer}');
    }

    return bad.isEmpty ? GateResult.ok : GateResult(false, bad);
  }
}
