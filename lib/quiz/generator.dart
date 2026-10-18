/// 本地出题器（题库）。
///
/// 三条铁律：
///   1) **数字本地随机、答案本地算**，模型不参与给数——这里刻意不用大模型生成题目
///   2) 每道题都必须过正确性闸门（不出负数、不出无限小数、三角形合法、余数小于除数）
///   3) 每道题都要有"像老师说话"的分步讲解，而不是把算式罗列一遍
///
/// 题库组织：每个题型是一个 _Factory，声明它命中的知识点关键字与适用年级。
/// 按知识点出题 = 按关键字筛出厂的子集再随机抽。
library;

import 'dart:math' as math;

import '../core/rational.dart';
import '../geometry/dsl/figure.dart';
import '../geometry/render/figure_svg.dart';
import '../geometry/solver/solid.dart';
import '../geometry/solver/solver.dart';
import '../knowledge/kp.dart';
import '../knowledge/kp_index.dart';
import '../render/vertical_svg.dart';
import '../typeset/vertical.dart';
import 'question.dart';

typedef ItemBuilder = QuizQuestion? Function(_Ctx c);

class _Ctx {
  final math.Random rnd;
  final int grade;
  final KnowledgeIndex index;
  final FigureSvgRenderer figureRenderer;
  final VerticalSvgRenderer verticalRenderer;
  int salt;

  _Ctx(this.rnd, this.grade, this.index, this.figureRenderer, this.verticalRenderer,
      this.salt);

  int ri(int min, int max) => min + rnd.nextInt(math.max(0, max - min + 1));

  T pick<T>(List<T> xs) => xs[rnd.nextInt(xs.length)];
}

class _Factory {
  final String id;
  final List<String> keys;
  final Set<int> grades;
  final ItemBuilder build;

  const _Factory(this.id, this.keys, this.grades, this.build);
}

/// 出题器。
class QuizGenerator {
  final KnowledgeIndex index;
  final FigureSvgRenderer figureRenderer;
  final VerticalSvgRenderer verticalRenderer;
  final math.Random rnd;

  int _saltCounter = 0;

  QuizGenerator({int? seed, KnowledgeIndex? index})
      : index = index ?? KnowledgeIndex(),
        figureRenderer = const FigureSvgRenderer(),
        verticalRenderer = const VerticalSvgRenderer(),
        rnd = math.Random(seed ?? DateTime.now().microsecondsSinceEpoch % 1000000);

  int get _salt {
    _saltCounter++;
    return DateTime.now().microsecondsSinceEpoch % 100000 + _saltCounter * 7919;
  }

  _Ctx _ctx(int grade) => _Ctx(rnd, grade, index, figureRenderer, verticalRenderer, _salt);

  /// 可用的全部题型。
  static const factories = <_Factory>[
    // ── 数与代数：计算 ────────────────────────────────
    _Factory('add-carry', ['进位加', '笔算加', '100 以内加减法', '连加连减'], {1, 2, 3},
        FCalc.add),
    _Factory('sub-borrow', ['退位减', '笔算减', '100 以内加减法'], {1, 2, 3}, FCalc.sub),
    _Factory('mul-2x1', ['笔算', '乘法口诀', '乘加乘减', '两位数乘一位数'], {2, 3, 4},
        FCalc.mul21),
    // mul-2x2 / rect-area 只到四年级：五年级家长明确反馈过
    // "五年级的题出现低年级的简单问题"。高年级池子只放本年级 native 题型，
    // 低年级内容要么在低年级练，要么由家长在下拉里显式选（关键词仍能命中）。
    _Factory('mul-2x2', ['笔算', '两位数乘两位数', '三位数乘两位数'], {3, 4}, FCalc.mul22),
    _Factory('div-rem', ['余数比除数小', '有余数除法', '表内除法', '平均分'], {2, 3, 4},
        FCalc.divRem),
    _Factory('mix-ops', ['混合运算', '两级运算', '小括号', '同级运算'], {2, 3, 4},
        FCalc.mixOps),
    _Factory('unit-conv', ['单位换算', '长度单位', '元角分', '认识人民币'], {2, 3, 4},
        FCalc.unitConv),

    // ── 图形与几何 ───────────────────────────────────
    _Factory('rect-area', ['长方形', '周长', '长方形和正方形的面积', '面积'], {3, 4},
        FGeom.rect),
    _Factory('triangle-area', ['三角形的面积', '三角形面积'], {5, 6}, FGeom.triangle),
    _Factory('parallelogram-area', ['平行四边形的面积', '平行四边形面积'], {5, 6},
        FGeom.parallelogram),
    _Factory('trapezoid-area', ['梯形的面积', '梯形面积'], {5, 6}, FGeom.trapezoid),
    _Factory('circle-area', ['圆的面积', '圆的周长', '圆的认识', '圆'], {6}, FGeom.circleArea),
    _Factory('circle-perim', ['圆的周长', '圆的认识', '圆'], {6}, FGeom.circlePerim),
    _Factory('composite-area', ['组合图形面积', '组合图形'], {5, 6}, FGeom.composite),
    _Factory('lattice-area', ['组合图形面积', '不规则图形', '数格子', '面积'], {4, 5, 6},
        FGeom.lattice),
    _Factory('cubenet', ['正方体的认识', '表面积', '展开图', '长正方体的认识'], {5, 6},
        FGeom.cubeNet),
    _Factory('cuboid-volume', ['长方体和正方体的体积', '体积', '容积'], {5, 6}, FGeom.cuboid),
    _Factory('cylinder-volume', ['圆柱的体积', '圆柱与圆锥', '圆柱'], {6}, FGeom.cylinder),

    // ── 综合与实践（应用题） ──────────────────────────
    _Factory('word-shopping', ['简单购物', '解决问题', '加减两步', '元角分'], {1, 2, 3},
        FWord.shopping),
    _Factory('word-average', ['平均数', '除法解决问题', '平均分'], {3, 4}, FWord.average),
    _Factory('word-times', ['倍的认识', '求一个数的几倍', '解决问题', '倍数'], {2, 3, 4},
        FWord.timesAs),
    _Factory('word-garden', ['植树', '间隔', '解决问题', '数学广角'], {3, 4, 5, 6},
        FWord.interval),
    _Factory('word-fraction', ['分数的意义', '求一个数的几分之几', '分数乘法'], {5, 6},
        FWord.fractionOf),
  ];

  /// 按知识点出题。[unit] / [tag] 来自知识点树，为空表示不限知识点。
  QuizQuestion generate({
    required int grade,
    String? unit,
    String? tag,
  }) {
    final pool = _poolFor(grade, unit, tag);
    for (var attempt = 0; attempt < 60; attempt++) {
      final q = pool[rnd.nextInt(pool.length)].build(_ctx(grade));
      if (q != null) return q;
    }
    // 兜底：题库再怎么着也得有题，否则 App 是空界面
    return FCalc.add(_ctx(grade)) ?? generate(grade: grade);
  }

  /// 出一组题（默认去重：同一份练习里不出现两道一模一样的）。
  List<QuizQuestion> generateMany({
    required int grade,
    String? unit,
    String? tag,
    int count = 5,
    bool dedupe = true,
  }) {
    final out = <QuizQuestion>[];
    final seen = <String>{};
    final pool = _poolFor(grade, unit, tag);
    for (var attempt = 0; attempt < count * 60 && out.length < count; attempt++) {
      final q = pool[rnd.nextInt(pool.length)].build(_ctx(grade));
      if (q == null) continue;
      if (dedupe && !seen.add(q.id)) continue;
      out.add(q);
    }
    return out;
  }

  /// 这个年级 + 知识点下，本地题库是否真有模板能出题。
  ///
  /// 下拉里列的是教材全部单元，题库只覆盖一部分（比如五年级
  /// "图形的运动（三）·旋转"就没有对应题型）。以前这种情况会静默
  /// 退回"出全部知识点的题"——家长选了旋转，拿到一道面积题。
  /// 现在把判断暴露出来：UI 可以诚实提示，并把这部分交给 AI 出题。
  bool covers({required int grade, String? unit, String? tag}) {
    final kw = <String>[if (unit != null) unit, if (tag != null) tag]
        .where((s) => s.trim().isNotEmpty)
        .toList();
    if (kw.isEmpty) return true;
    return factories.any((f) =>
        f.grades.contains(grade) &&
        kw.any((k) => f.keys.any((key) => k.contains(key) || key.contains(k))));
  }

  List<_Factory> _poolFor(int grade, String? unit, String? tag) {    Iterable<_Factory> it = factories.where((f) => f.grades.contains(grade));
    var list = it.toList();
    final kw = <String>[if (unit != null) unit, if (tag != null) tag]
        .where((s) => s.trim().isNotEmpty)
        .toList();
    if (kw.isNotEmpty) {
      final matched = list
          .where((f) => kw.any((k) => f.keys.any((key) => k.contains(key) || key.contains(k))))
          .toList();
      if (matched.isNotEmpty) return matched;
    }
    if (list.isNotEmpty) return list;
    // 该年级没有匹配的题型时，退到相邻年级，绝不返回空列表（空列表 = 空界面）
    final fallback = factories
        .where((f) => (f.grades.contains(grade - 1)) || f.grades.contains(grade + 1))
        .toList();
    return fallback.isNotEmpty
        ? fallback
        : [factories.firstWhere((f) => f.id == 'add-carry')];
  }
}

// ════════════════════ 数与代数 ════════════════════

class FCalc {
  static QuizQuestion? add(_Ctx c) {
    final maxN = c.grade <= 1 ? 20 : (c.grade == 2 ? 99 : 999);
    final a = c.ri(1, maxN);
    final b = c.ri(1, maxN);
    if (a + b > maxN * 2) return null;
    // 闸门：低年级必须进位，否则就不叫"进位加"
    if (c.grade <= 2 && !Util.anyCarry(a, b)) return null;

    final layout = VerticalTypeset.add(a, b);
    return QuizQuestion(
      id: 'add-$a-$b',
      kpPath: Util.kpPath(c, '不进位加'),
      kpCode: Util.kpCode(c, '不进位加'),
      grade: c.grade,
      stem: '用竖式算一算：$a + $b =',
      verticalSvg: c.verticalRenderer.render(layout),
      solutionSteps: layout.steps,
      answer: QuizAnswer(display: '${a + b}', value: (a + b).toDouble()),
      kind: 'add',
      verticalKind: 'add',
      verticalArgs: [a, b],
      difficulty: c.grade <= 1 ? 1 : 2,
    );
  }

  static QuizQuestion? sub(_Ctx c) {
    final maxN = c.grade <= 1 ? 20 : (c.grade == 2 ? 99 : 999);
    final a = c.ri(2, maxN);
    final b = c.ri(1, a - 1);
    if (c.grade <= 2 && !Util.anyBorrow(a, b)) return null;

    final layout = VerticalTypeset.sub(a, b);
    return QuizQuestion(
      id: 'sub-$a-$b',
      kpPath: Util.kpPath(c, '退位减'),
      kpCode: Util.kpCode(c, '退位减'),
      grade: c.grade,
      stem: '用竖式算一算：$a − $b =',
      verticalSvg: c.verticalRenderer.render(layout),
      solutionSteps: layout.steps,
      answer: QuizAnswer(display: '${a - b}', value: (a - b).toDouble()),
      kind: 'sub',
      verticalKind: 'sub',
      verticalArgs: [a, b],
      difficulty: c.grade <= 1 ? 1 : 2,
    );
  }

  static QuizQuestion? mul21(_Ctx c) {
    final a = c.ri(c.grade >= 4 ? 21 : 12, c.grade >= 4 ? 89 : 39);
    final b = c.ri(3, 9);
    final layout = VerticalTypeset.mul(a, b);
    final sum = a * b;
    return QuizQuestion(
      id: 'mul21-$a-$b',
      kpPath: Util.kpPath(c, '笔算'),
      kpCode: Util.kpCode(c, '笔算'),
      grade: c.grade,
      stem: '用竖式算一算：$a × $b =',
      verticalSvg: c.verticalRenderer.render(layout),
      solutionSteps: layout.steps,
      answer: QuizAnswer(display: '$sum', value: sum.toDouble()),
      kind: 'mul',
      verticalKind: 'mul',
      verticalArgs: [a, b],
      difficulty: 2,
    );
  }

  static QuizQuestion? mul22(_Ctx c) {
    final a = c.ri(11, c.grade >= 5 ? 99 : 49);
    final b = c.ri(11, c.grade >= 5 ? 89 : 29);
    final layout = VerticalTypeset.mul(a, b);
    final sum = a * b;
    return QuizQuestion(
      id: 'mul22-$a-$b',
      kpPath: Util.kpPath(c, '笔算'),
      kpCode: Util.kpCode(c, '笔算'),
      grade: c.grade,
      stem: '用竖式算一算：$a × $b =',
      verticalSvg: c.verticalRenderer.render(layout),
      solutionSteps: layout.steps,
      answer: QuizAnswer(display: '$sum', value: sum.toDouble()),
      kind: 'mul',
      verticalKind: 'mul',
      verticalArgs: [a, b],
      difficulty: 3,
    );
  }

  /// 有余数除法。闸门：余数必须小于除数（这条正是孩子们最容易错的规矩）。
  static QuizQuestion? divRem(_Ctx c) {
    final b = c.ri(4, 9);
    final q = c.ri(2, c.grade >= 4 ? 19 : 9);
    final r = c.ri(1, b - 1);
    final a = b * q + r;
    if (a < 10) return null;

    final d = VerticalTypeset.div(a, b);
    return QuizQuestion(
      id: 'div-$a-$b',
      kpPath: Util.kpPath(c, '余数比除数小'),
      kpCode: Util.kpCode(c, '余数比除数小'),
      grade: c.grade,
      stem: '用竖式算一算：$a ÷ $b =',
      verticalSvg: c.verticalRenderer.renderLongDivision(d),
      verticalKind: 'div',
      verticalArgs: [a, b],
      solutionSteps: [
        '想：$b 乘几最接近 $a 又不超过它？$b × $q = ${b * q}。',
        '$a 减 ${b * q} 得 $r。',
        '余数 $r 比除数 $b 小，说明试对了。',
        '结果是 $q 余 $r。',
      ],
      answer: QuizAnswer(
        display: '$q …… $r',
        value: q.toDouble(),
        unit: '余 $r',
        tolerance: 0.0, // 余数写法是文本，不能只比数值
        accepts: ['$q…$r', '$q…$r 余', '$q余$r', '$q…$r（余$r）'],
      ),
      kind: 'divRem',
      difficulty: 2,
    );
  }

  /// 两级运算：先乘除后加减。闸门：结果为整数且不为负。
  static QuizQuestion? mixOps(_Ctx c) {
    final x = c.ri(3, 9);
    final y = c.ri(3, 9);
    final product = x * y;
    final add = c.ri(10, 99);
    if (add <= product) return null;

    final useMinus = c.rnd.nextBool();
    final res = useMinus ? add - product : add + product;
    if (res < 0) return null;
    final stem = useMinus ? '$add − $x × $y' : '$add + $x × $y';

    return QuizQuestion(
      id: 'mix-$stem',
      kpPath: Util.kpPath(c, '两级运算'),
      kpCode: Util.kpCode(c, '两级运算'),
      grade: c.grade,
      stem: '先想清楚运算顺序，再算：$stem =',
      solutionSteps: [
        '这道题里有加减，也有乘法，要先算乘法。',
        '先算 $x × $y = $product。',
        useMinus ? '再算 $add − $product = $res。' : '再算 $add + $product = $res。',
        '结果是 $res。',
      ],
      answer: QuizAnswer(display: '$res', value: res.toDouble()),
      kind: 'mixOps',
      difficulty: 3,
    );
  }

  /// 单位换算：闸门是不出奇怪的换算（只在同类的相邻单位间换）。
  static QuizQuestion? unitConv(_Ctx c) {
    final cases = <(String, String, int, String, int)>[
      ('3 米 = （   ）厘米', '3 米等于多少厘米', 100, '米→厘米', 2),
      ('250 厘米 = （   ）米（   ）厘米', '250 厘米是几米几厘米', 100, '厘米→米', 3),
      ('5 元 6 角 = （   ）角', '5 元 6 角一共多少角', 10, '元→角', 2),
      ('80 分 = （   ）角', '80 分是多少角', 10, '分→角', 2),
      ('4 时 = （   ）分', '4 小时是多少分', 60, '时→分', 3),
      ('2 千克 = （   ）克', '2 千克是多少克', 1000, '千克→克', 3),
    ];
    final pick = cases[c.rnd.nextInt(cases.length)];
    switch (pick.$4) {
      case '米→厘米':
        final m = c.ri(2, 9);
        return _unitQ(c, '$m 米 = （   ）厘米', '米和厘米之间是 100 进的：1 米 = 100 厘米。',
            '$m × 100 = ${m * 100}。', (m * 100).toDouble(), '厘米');
      case '厘米→米':
        final cm = c.ri(2, 9) * 100 + c.ri(1, 9) * 10;
        final mm = cm ~/ 100;
        final rest = cm % 100;
        return _unitQ(c, '$cm 厘米 = （   ）米（   ）厘米',
            '看里面有几个 100 厘米，就是几米。', '$cm 厘米里有 $mm 个 100，还剩 $rest 厘米。',
            (mm + rest / 100).toDouble(), '米 厘米', display: '$mm 米 $rest 厘米');
      case '元→角':
        final yuan = c.ri(1, 9);
        final jiao = c.ri(1, 9);
        return _unitQ(c, '$yuan 元 $jiao 角 = （   ）角',
            '先把元换成角：1 元 = 10 角。', '$yuan 元 = ${yuan * 10} 角，再加 $jiao 角。',
            (yuan * 10 + jiao).toDouble(), '角');
      case '分→角':
        final fen = c.ri(1, 9) * 10;
        return _unitQ(c, '$fen 分 = （   ）角', '1 角 = 10 分，看有几个 10 分。',
            '$fen 分里有 ${fen ~/ 10} 个 10 分。', (fen ~/ 10).toDouble(), '角');
      case '时→分':
        final h = c.ri(2, 5);
        return _unitQ(c, '$h 时 = （   ）分', '1 时 = 60 分。', '$h × 60 = ${h * 60}。',
            (h * 60).toDouble(), '分');
      default:
        final kg = c.ri(2, 9);
        return _unitQ(c, '$kg 千克 = （   ）克', '1 千克 = 1000 克。',
            '$kg × 1000 = ${kg * 1000}。', (kg * 1000).toDouble(), '克');
    }
  }

  static QuizQuestion _unitQ(
      _Ctx c, String stem, String step1, String step2, double value, String unit,
      {String? display}) {
    return QuizQuestion(
      id: 'unit-${stem.hashCode}',
      kpPath: Util.kpPath(c, '换算'),
      kpCode: Util.kpCode(c, '换算'),
      grade: c.grade,
      stem: '填一填：$stem',
      solutionSteps: [step1, step2, '答案是 ${display ?? Util.n(value)}。'],
      answer: QuizAnswer(
        display: display ?? Util.n(value),
        value: value,
        unit: unit,
        tolerance: 0.011,
      ),
      kind: 'unitConv',
      difficulty: 2,
    );
  }
}

// ════════════════════ 图形与几何 ════════════════════

class FGeom {
  static QuizQuestion rect(_Ctx c) {
    final w = c.ri(c.grade >= 4 ? 6 : 2, c.grade >= 4 ? 12 : 9);
    final h = c.ri(2, c.grade >= 4 ? 9 : 6);
    final askArea = c.rnd.nextBool();
    final spec = FigureSpec(type: FigureType.rect, params: {'w': w * 1.0, 'h': h * 1.0},
        unit: 'cm', grade: c.grade, shade: !askArea);
    final solved = FigureSolver.solve(spec);
    final area = w * h;
    final perim = 2 * (w + h);

    return QuizQuestion(
      id: 'rect-$w-$h-${askArea ? 'a' : 'p'}',
      kpPath: Util.kpPath(c, '长方形'),
      kpCode: Util.kpCode(c, '长方形'),
      grade: c.grade,
      stem: askArea
          ? '一个长方形，长 $w 厘米，宽 $h 厘米，它的面积是多少平方厘米？'
          : '一个长方形，长 $w 厘米，宽 $h 厘米，它的周长是多少厘米？',
      figureSvg: c.figureRenderer.render(solved.scene, widthPx: 230, idPrefix: 'rect$w$h'),
      figureSpec: spec.toJson(),
      solutionSteps: askArea
          ? [
              '长方形的面积 = 长 × 宽。',
              '把数代进去：$w × $h = $area。',
              '记得面积单位要写"平方厘米"。',
            ]
          : [
              '周长就是绕着图形走一圈的长度。',
              '长方形有两条长、两条宽，所以（$w + $h）× 2 = $perim。',
              '周长单位还是"厘米"。',
            ],
      answer: QuizAnswer(
        display: askArea ? '$area' : '$perim',
        value: (askArea ? area : perim).toDouble(),
        unit: askArea ? '平方厘米' : '厘米',
      ),
      kind: 'rect',
      difficulty: 2,
    );
  }

  static QuizQuestion triangle(_Ctx c) {
    final base = c.ri(4, 12);
    final height = c.ri(3, 9);
    final area = Rational.fromBig(
        BigInt.from(base) * BigInt.from(height), BigInt.from(2));
    if (!area.hasFiniteDecimal) return triangle(c);
    final isRight = c.rnd.nextBool();
    final spec = isRight
        ? FigureSpec(type: FigureType.triangleRight,
            params: {'a': base * 1.0, 'b': height * 1.0}, unit: 'cm', grade: c.grade)
        : FigureSpec(type: FigureType.triangleGeneral, params: {
            'a': base * 1.0,
            'h': height * 1.0,
            // 垂足位置随机偏左或偏右，保证画出的是斜三角形且每次略有变化
            'foot': c.rnd.nextBool() ? 0.3 : 0.7,
          }, unit: 'cm', grade: c.grade);
    final solved = FigureSolver.solve(spec);

    return QuizQuestion(
      id: 'tri-$base-$height',
      kpPath: Util.kpPath(c, '三角形的面积'),
      kpCode: Util.kpCode(c, '三角形的面积'),
      grade: c.grade,
      stem: '一个三角形的底是 $base 厘米，高是 $height 厘米，它的面积是多少平方厘米？',
      figureSvg: c.figureRenderer.render(solved.scene, widthPx: 230, idPrefix: 'tri$base$height'),
      figureSpec: spec.toJson(),
      solutionSteps: [
        '三角形的面积 = 底 × 高 ÷ 2。',
        '先算 $base × $height = ${base * height}，再除以 2。',
        '答案是 ${area.toMixedString()} 平方厘米。注意别忘÷2——这是最常见的错。',
      ],
      answer: QuizAnswer(
        display: area.toMixedString(),
        value: area.toDouble(),
        unit: '平方厘米',
        accepts: [Util.n(base * height / 2)],
      ),
      kind: 'triangle',
      difficulty: 3,
    );
  }

  static QuizQuestion parallelogram(_Ctx c) {
    final base = c.ri(4, 12);
    final height = c.ri(3, 9);
    final area = base * height;
    final spec = FigureSpec(type: FigureType.parallelogram,
        params: {'base': base * 1.0, 'height': height * 1.0, 'offset': 3.0},
        unit: 'cm', grade: c.grade);
    final solved = FigureSolver.solve(spec);

    return QuizQuestion(
      id: 'para-$base-$height',
      kpPath: Util.kpPath(c, '平行四边形的面积'),
      kpCode: Util.kpCode(c, '平行四边形的面积'),
      grade: c.grade,
      stem: '一个平行四边形的底是 $base 厘米，高是 $height 厘米，它的面积是多少平方厘米？',
      figureSvg: c.figureRenderer.render(solved.scene, widthPx: 250, idPrefix: 'para$base$height'),
      figureSpec: spec.toJson(),
      solutionSteps: [
        '平行四边形的面积 = 底 × 高。',
        '这里的高必须是"垂直的那条"，不是斜边——图上虚线才是高。',
        '面积 = $base × $height = $area 平方厘米。',
      ],
      answer: QuizAnswer(display: '$area', value: area.toDouble(), unit: '平方厘米'),
      kind: 'parallelogram',
      difficulty: 3,
    );
  }

  static QuizQuestion trapezoid(_Ctx c) {
    final top = c.ri(3, 8);
    var bottom = top + c.ri(2, 8);
    final height = c.ri(3, 9);
    final sumH = (top + bottom) * height;
    // 闸门：（上底+下底）× 高 必须是偶数，否则答案是小数，超出小学常用范围
    if (sumH.isOdd) bottom += 1;
    final area = ((top + bottom) * height) ~/ 2;
    final spec = FigureSpec(type: FigureType.trapezoid,
        params: {'top': top * 1.0, 'bottom': bottom * 1.0, 'height': height * 1.0},
        unit: 'cm', grade: c.grade);
    final solved = FigureSolver.solve(spec);

    return QuizQuestion(
      id: 'trap-$top-$bottom-$height',
      kpPath: Util.kpPath(c, '梯形的面积'),
      kpCode: Util.kpCode(c, '梯形的面积'),
      grade: c.grade,
      stem: '一个梯形，上底 $top 厘米，下底 $bottom 厘米，高 $height 厘米，它的面积是多少平方厘米？',
      figureSvg: c.figureRenderer.render(solved.scene, widthPx: 250,
          idPrefix: 'trap$top$bottom$height'),
      figureSpec: spec.toJson(),
      solutionSteps: [
        '梯形的面积 =（上底 + 下底）× 高 ÷ 2。',
        '先算上底加下底：$top + $bottom = ${top + bottom}。',
        '再乘高：${top + bottom} × $height = ${(top + bottom) * height}。',
        '最后除以 2：$area。别忘了这一步。',
      ],
      answer: QuizAnswer(display: '$area', value: area.toDouble(), unit: '平方厘米'),
      kind: 'trapezoid',
      difficulty: 3,
    );
  }

  static QuizQuestion circleArea(_Ctx c) {
    final r = c.ri(2, 9);
    final areaPi = r * r;
    final area = areaPi * 3.14;
    final spec = FigureSpec(type: FigureType.circle, params: {'r': r * 1.0},
        unit: 'cm', grade: c.grade);
    final solved = FigureSolver.solve(spec);

    return QuizQuestion(
      id: 'circle-a-$r',
      kpPath: Util.kpPath(c, '圆的面积'),
      kpCode: Util.kpCode(c, '圆的面积'),
      grade: c.grade,
      stem: '一个圆的半径是 $r 厘米，它的面积是多少平方厘米？（π 取 3.14）',
      figureSvg: c.figureRenderer.render(solved.scene, widthPx: 210, idPrefix: 'cir$r'),
      figureSpec: spec.toJson(),
      solutionSteps: [
        '圆的面积 = π × r × r。',
        '先算 r × r：$r × $r = $areaPi。',
        '再乘 π（取 3.14）：$areaPi × 3.14 = ${Util.n(area)}。',
        '注意半径和直径别看错——弄混了就差 4 倍。',
      ],
      answer: QuizAnswer(
        display: Util.n(area),
        value: area,
        unit: '平方厘米',
        tolerance: 0.06,
        accepts: [Util.n(areaPi * math.pi)],
      ),
      kind: 'circleArea',
      difficulty: 3,
    );
  }

  static QuizQuestion circlePerim(_Ctx c) {
    final r = c.ri(2, 9);
    final d = 2 * r;
    final perim = d * 3.14;
    final spec = FigureSpec(type: FigureType.circle, params: {'r': r * 1.0},
        unit: 'cm', grade: c.grade);
    final solved = FigureSolver.solve(spec);

    return QuizQuestion(
      id: 'circle-p-$r',
      kpPath: Util.kpPath(c, '圆的周长'),
      kpCode: Util.kpCode(c, '圆的周长'),
      grade: c.grade,
      stem: '一个圆的半径是 $r 厘米，它的周长是多少厘米？（π 取 3.14）',
      figureSvg: c.figureRenderer.render(solved.scene, widthPx: 210, idPrefix: 'cirp$r'),
      figureSpec: spec.toJson(),
      solutionSteps: [
        '周长 = π × 直径，也就是 C = πd。',
        '半径是 $r，直径就是 $r × 2 = $d。',
        '再乘 π（取 3.14）：$d × 3.14 = ${Util.n(perim)}。',
      ],
      answer: QuizAnswer(
        display: Util.n(perim),
        value: perim,
        unit: '厘米',
        tolerance: 0.06,
        accepts: [Util.n(d * math.pi)],
      ),
      kind: 'circlePerim',
      difficulty: 3,
    );
  }

  /// 组合图形：长方形上接一个半圆。闸门：半径=宽/2，宽必须是偶数。
  static QuizQuestion composite(_Ctx c) {
    final w = [6.0, 8.0, 10.0, 12.0][c.rnd.nextInt(4)];
    final h = c.ri(3, 8).toDouble();
    final r = w / 2;
    final rectArea = w * h;
    final semiArea = r * r * 3.14 / 2;
    final total = rectArea + semiArea;
    final spec = FigureSpec(type: FigureType.compositeRectSemicircle,
        params: {'w': w, 'h': h}, unit: 'cm', grade: c.grade, shade: true);
    final solved = FigureSolver.solve(spec);

    return QuizQuestion(
      id: 'comp-${w.toInt()}-${h.toInt()}',
      kpPath: Util.kpPath(c, '组合图形'),
      kpCode: Util.kpCode(c, '组合图形'),
      grade: c.grade,
      stem: '下面是一个组合图形：长方形上面接一个半圆。长方形长 ${Util.n(w)} 厘米、宽 ${Util.n(h)} 厘米，求它的面积。（π 取 3.14）',
      figureSvg: c.figureRenderer.render(solved.scene, widthPx: 250,
          idPrefix: 'comp${w.toInt()}${h.toInt()}'),
      figureSpec: spec.toJson(),
      solutionSteps: [
        '组合图形要拆成两块熟图形分开算，再合起来。',
        '长方形：${Util.n(w)} × ${Util.n(h)} = ${Util.n(rectArea)} 平方厘米。',
        '半圆的半径是长方形长的一半：${Util.n(w)} ÷ 2 = ${Util.n(r)} 厘米。',
        '半圆面积 = πr² ÷ 2 = ${Util.n(r * r * 3.14)} ÷ 2 = ${Util.n(semiArea)} 平方厘米。',
        '合起来：${Util.n(rectArea)} + ${Util.n(semiArea)} = ${Util.n(total)} 平方厘米。',
      ],
      answer: QuizAnswer(
        display: Util.n(total),
        value: total,
        unit: '平方厘米',
        tolerance: 0.06,
      ),
      kind: 'composite',
      difficulty: 4,
    );
  }

  /// 格点不规则图形：答案由鞋带公式 + Pick 定理交叉验证（本地算，永不给错）。
  static QuizQuestion lattice(_Ctx c) {
    final seed = c.rnd.nextInt(100000);
    final w = c.ri(4, 6);
    final h = c.ri(3, 5);
    final spec = FigureSpec(type: FigureType.latticePolygon,
        params: {'seed': seed, 'width': w, 'height': h},
        unit: 'cm', grade: c.grade, shade: true);
    SolveResult solved;
    try {
      solved = FigureSolver.solve(spec);
    } catch (_) {
      return lattice(c);
    }
    final area = solved.facts['area']!.exact!;
    if (area <= Rational.zero) return lattice(c);

    return QuizQuestion(
      id: 'lat-$seed-$w-$h',
      kpPath: Util.kpPath(c, '组合图形面积'),
      kpCode: Util.kpCode(c, '组合图形面积'),
      grade: c.grade,
      stem: '下面的图形画在方格纸上，每个小方格的边长都是 1 厘米。它的面积是多少平方厘米？',
      figureSvg: c.figureRenderer.render(solved.scene, widthPx: 260, idPrefix: 'lat$seed'),
      figureSpec: spec.toJson(),
      solutionSteps: [
        '这种不规则图形用"数格子"最快：先数完整的格子。',
        '不满一格的，把两个半格凑成一格、两个不满半格合成一格。',
        '也可以用包在外面的长方形减去旁边空出来的部分，两种方法应当算出同一个数。',
        '答案是 ${area.toMixedString()} 平方厘米。',
      ],
      answer: QuizAnswer(
        display: area.toMixedString(),
        value: area.toDouble(),
        unit: '平方厘米',
        tolerance: 0.011,
        accepts: [Util.n(area.toDouble())],
      ),
      kind: 'lattice',
      difficulty: 4,
    );
  }

  /// 正方体展开图：判断题一半可折一半不可折（真·判断题），
  /// 求表面积的题只用可折的（图配"正方体"的题面，不能给个折不起来的网）。
  static QuizQuestion cubeNet(_Ctx c) {
    final askFold = c.rnd.nextBool();
    // 可折的：十字/一四一/二二二/三三；不可折的：2×3 矩形 / 两片同侧。
    // 曾经池子里只有四个可折布局，"判断"题答案永远是"能"——
    // 孩子无脑答"能"就能全对，这题就白出了。
    final layout = askFold
        ? (c.rnd.nextBool()
            ? CubeNet.traps[c.rnd.nextInt(CubeNet.traps.length)].name
            : CubeNet.builtin[c.rnd.nextInt(CubeNet.builtin.length)].name)
        : CubeNet.builtin[c.rnd.nextInt(CubeNet.builtin.length)].name;
    final net = CubeNet.byName(layout)!;
    final foldable = CubeNetValidator.isFoldable(net);
    final edge = c.ri(2, 6);
    final spec = FigureSpec(type: FigureType.cubeNet,
        params: {'edge': edge * 1.0}, unit: 'cm', grade: c.grade,
        text: {'layout': layout});
    final solved = FigureSolver.solve(spec);
    final surface = 6 * edge * edge;

    // 判断怎么折/为什么折不成的解释，必须对着图说 ——
    // "中间一排四个"只对一四一型成立，对二二二/三三/矩形是胡说。
    final String why;
    switch (layout) {
      case 'cross':
      case 'stair':
        why = foldable
            ? '能。中间一排四个围成一圈当侧面，上下两片正好折成顶和底，六个面互不重叠。'
            : '';
      case 'zigzag':
        why = '能。像楼梯一样两层两层错开，折的时候每个面转半圈正好接上，围成一圈。';
      case 'twin':
        why = '能。两排各三片、错开两格，折起来下面一排补成底面，上面一排围成侧面和顶。';
      case 'rect23':
        why = '不能。六个面排成整整齐齐的 2×3，折到一半就会有两个面叠在同一个位置，同时还有一个面空着。';
      case 'twotop':
        why = '不能。四个一排折成侧面后，上面那两片折下来都盖在同一个"顶"上——顶面叠了两层，底面却空着。';
      default:
        why = foldable ? '能。六个面折起来正好互不重叠地围一圈。' : '不能。折起来会有面叠在一起。';
    }
    final tip = foldable
        ? '快速判断的小窍门：先数是不是 6 个面，再顺着图折一折，看六个面是不是各占一面。'
        : '快速判断的小窍门：排成 2×2、2×3 或"田"字样的，或者两片折向同一边的，多半折不成——会有面叠上。';

    if (askFold) {
      return QuizQuestion(
        id: 'cubenet-$layout',
        kpPath: Util.kpPath(c, '正方体的认识'),
        kpCode: Util.kpCode(c, '正方体的认识'),
        grade: c.grade,
        stem: '下面这个展开图能不能折成一个正方体？先判断，再说说理由。',
        figureSvg: c.figureRenderer.render(solved.scene, widthPx: 230, idPrefix: 'cn$layout'),
      figureSpec: spec.toJson(),
        solutionSteps: [why, tip,
          '更稳的办法是动手剪下来折一下——这是最不像窍门的真窍门。',
        ],
        answer: QuizAnswer(
          display: foldable ? '能' : '不能',
          accepts: foldable
              ? ['能', '可以', '能折成正方体', '能折成', '是', 'yes']
              : ['不能', '不可以', '不能折成正方体', '不能折成', '否', 'no'],
        ),
        kind: 'cubeNet',
        difficulty: 3,
      );
    }
    return QuizQuestion(
      id: 'cubesurf-$edge',
      kpPath: Util.kpPath(c, '表面积'),
      kpCode: Util.kpCode(c, '表面积'),
      grade: c.grade,
      stem: '一个正方体的棱长是 $edge 厘米，它的表面积是多少平方厘米？',
      figureSvg: c.figureRenderer.render(solved.scene, widthPx: 200, idPrefix: 'cs$edge'),
      figureSpec: spec.toJson(),
      solutionSteps: [
        '正方体有 6 个面，而且每个面都是一样的正方形。',
        '一个面的面积：$edge × $edge = ${edge * edge}。',
        '6 个面加起来：${edge * edge} × 6 = $surface。',
      ],
      answer: QuizAnswer(display: '$surface', value: surface.toDouble(), unit: '平方厘米'),
      kind: 'cuboidSurface',
      difficulty: 3,
    );
  }

  static QuizQuestion cuboid(_Ctx c) {
    final a = c.ri(3, 9);
    final b = c.ri(2, 7);
    final h = c.ri(2, 6);
    final vol = a * b * h;
    final surface = 2 * (a * b + a * h + b * h);
    final askVol = c.rnd.nextBool();
    // 注意键名：SolidBuilder.cuboidOblique 读的是 w/h/d（底面边长/高/进深）。
    // 曾经这里传 a/b/c，三个键全部落空，图形永远按默认值 5/3/2 画，
    // 于是出现"题面写 长5宽3高6、图上标 3/5/2"的诡异卷子。
    final spec = FigureSpec(type: FigureType.cuboidOblique,
        params: {'w': a * 1.0, 'h': h * 1.0, 'd': b * 1.0}, unit: 'cm', grade: c.grade);
    final solved = FigureSolver.solve(spec);

    return QuizQuestion(
      id: 'cuboid-$a-$b-$h-${askVol ? 'v' : 's'}',
      // 问体积挂"体积"、问表面积挂"表面积"——同单元不同考点，
      // 错题本按考点聚类时不该把表面积题归进体积。
      kpPath: Util.kpPath(c, askVol ? '体积' : '表面积'),
      kpCode: Util.kpCode(c, askVol ? '体积' : '表面积'),
      grade: c.grade,
      stem: askVol
          ? '一个长方体，长 $a 厘米，宽 $b 厘米，高 $h 厘米，它的体积是多少立方厘米？'
          : '一个长方体，长 $a 厘米，宽 $b 厘米，高 $h 厘米，它的表面积是多少平方厘米？',
      figureSvg: c.figureRenderer.render(solved.scene, widthPx: 240, idPrefix: 'cb$a$b$h'),
      figureSpec: spec.toJson(),
      solutionSteps: askVol
          ? [
              '长方体的体积 = 长 × 宽 × 高。',
              '$a × $b = ${a * b}，再乘 $h。',
              '体积是 $vol 立方厘米。',
            ]
          : [
              '长方体六个面，两两一样，所以要算三组面各一次再 ×2。',
              '上下：${a} × ${b} = ${a * b}；前后：${a} × ${h} = ${a * h}；左右：${b} × ${h} = ${b * h}。',
              '（${a * b} + ${a * h} + ${b * h}）× 2 = $surface。',
            ],
      answer: QuizAnswer(
        display: askVol ? '$vol' : '$surface',
        value: (askVol ? vol : surface).toDouble(),
        unit: askVol ? '立方厘米' : '平方厘米',
      ),
      kind: 'cuboid',
      difficulty: 3,
    );
  }

  static QuizQuestion cylinder(_Ctx c) {
    final r = c.ri(2, 6);
    final h = c.ri(4, 10);
    final vol = r * r * 3.14 * h;
    final spec = FigureSpec(type: FigureType.cylinder,
        params: {'r': r * 1.0, 'h': h * 1.0}, unit: 'cm', grade: c.grade);
    final solved = FigureSolver.solve(spec);

    return QuizQuestion(
      id: 'cyl-$r-$h',
      kpPath: Util.kpPath(c, '圆柱的体积'),
      kpCode: Util.kpCode(c, '圆柱的体积'),
      grade: c.grade,
      stem: '一个圆柱的底面半径是 $r 厘米，高是 $h 厘米，它的体积是多少立方厘米？（π 取 3.14）',
      figureSvg: c.figureRenderer.render(solved.scene, widthPx: 240, idPrefix: 'cy$r$h'),
      figureSpec: spec.toJson(),
      solutionSteps: [
        '圆柱的体积 = 底面积 × 高。',
        '先算底面这个圆：$r × $r × 3.14 = ${Util.n(r * r * 3.14)} 平方厘米。',
        '再乘高：${Util.n(r * r * 3.14)} × $h = ${Util.n(vol)} 立方厘米。',
      ],
      answer: QuizAnswer(
        display: Util.n(vol),
        value: vol,
        unit: '立方厘米',
        tolerance: 0.6,
        accepts: [Util.n(r * r * math.pi * h)],
      ),
      kind: 'cylinder',
      difficulty: 4,
    );
  }
}

// ════════════════════ 应用题 ════════════════════

class FWord {
  static QuizQuestion shopping(_Ctx c) {
    final unitPrices = [2, 3, 4, 5, 6, 8, 9];
    final price = unitPrices[c.rnd.nextInt(unitPrices.length)];
    final qty = c.ri(2, c.grade >= 3 ? 8 : 5);
    final paid = ((qty * price) ~/ 10 + c.ri(1, 6)) * 10; // 闸门：付的钱必须够
    if (paid < qty * price) return shopping(c);
    final total = qty * price;
    final change = paid - total;
    final goods = ['铅笔', '笔记本', '橡皮', '练习本', '水彩笔'][c.rnd.nextInt(5)];

    return QuizQuestion(
      id: 'shop-$price-$qty-$paid',
      kpPath: Util.kpPath(c, '简单购物'),
      kpCode: Util.kpCode(c, '简单购物'),
      grade: c.grade,
      stem: '小明买了 $qty 支$goods，每支 $price 元，付给售货员 $paid 元，应找回多少元？',
      solutionSteps: [
        '先算一共花了多少钱：这是求几个几，用乘法。',
        '$price × $qty = $total 元。',
        '再用付的钱减去花掉的钱：$paid − $total = $change 元。',
        '答：应找回 $change 元。',
      ],
      answer: QuizAnswer(display: '$change', value: change.toDouble(), unit: '元'),
      kind: 'shopping',
      difficulty: 2,
    );
  }

  /// 平均数：闸门是保证能整除（小学阶段不出现小数平均分）。
  static QuizQuestion average(_Ctx c) {
    final n = [3, 4, 5][c.rnd.nextInt(3)];
    final avg = c.ri(c.grade >= 4 ? 8 : 3, c.grade >= 4 ? 40 : 20);
    final total = avg * n;
    // 造一组和为 total 的数
    final xs = <int>[];
    var left = total;
    for (var i = 0; i < n - 1; i++) {
      final v = c.ri(1, (left / (n - i) * 2).round().clamp(2, 100));
      xs.add(v);
      left -= v;
    }
    xs.add(left);
    if (xs.last <= 0) return average(c);
    final list = xs.join('、');

    return QuizQuestion(
      id: 'avg-${xs.join('_')}',
      kpPath: Util.kpPath(c, '平均数'),
      kpCode: Util.kpCode(c, '平均数'),
      grade: c.grade,
      stem: '小芳一周跳绳的次数分别是 $list 下，她平均每天跳多少下？',
      solutionSteps: [
        '求平均数的方法：总数量 ÷ 总份数。',
        '先求一共：${xs.join(' + ')} = $total 下。',
        '一共 $n 天，所以用 $total ÷ $n = $avg 下。',
        '平均数不是"最多的那个数"，也不是"中间那个数"，是拉平之后的值。',
      ],
      answer: QuizAnswer(display: '$avg', value: avg.toDouble(), unit: '下'),
      kind: 'average',
      difficulty: 3,
    );
  }

  static QuizQuestion timesAs(_Ctx c) {
    final k = [2, 3, 4, 5, 6][c.rnd.nextInt(5)];
    final base = c.ri(3, c.grade >= 4 ? 40 : 15);
    final target = base * k;
    final askSum = c.rnd.nextBool();

    return QuizQuestion(
      id: 'times-$k-$base-${askSum ? 's' : 'o'}',
      kpPath: Util.kpPath(c, '倍的认识'),
      kpCode: Util.kpCode(c, '倍的认识'),
      grade: c.grade,
      stem: askSum
          ? '图书角有故事书 $base 本，科技书的本数是故事书的 $k 倍，两种书一共多少本？'
          : '图书角有故事书 $base 本，科技书的本数是故事书的 $k 倍，科技书有多少本？',
      solutionSteps: askSum
          ? [
              '先求科技书：故事书的 $k 倍，就是 $k 个 $base。',
              '$base × $k = $target 本。',
              '题目问的是"一共"，所以还要加回故事书：$target + $base = ${target + base} 本。',
              '这里最容易漏掉最后一步——看到"倍"就算完了。',
            ]
          : [
              '求一个数的几倍是多少，用乘法。',
              '$base × $k = $target 本。',
              '答：科技书有 $target 本。',
            ],
      answer: QuizAnswer(
        display: askSum ? '${target + base}' : '$target',
        value: (askSum ? target + base : target).toDouble(),
        unit: '本',
      ),
      kind: 'timesAs',
      difficulty: 3,
    );
  }

  /// 间隔问题（植树）：三种题型都要保证答案是整数（闸门）。
  static QuizQuestion interval(_Ctx c) {
    final which = c.rnd.nextInt(3);
    final trees = c.ri(5, 15);
    final gap = c.ri(2, 7);
    if (which == 0) {
      final len = (trees - 1) * gap;
      return QuizQuestion(
        id: 'iv0-$trees-$gap',
        kpPath: Util.kpPath(c, '植树'),
        kpCode: Util.kpCode(c, '植树'),
        grade: c.grade,
        stem: '同学们在一条小路的一边植树，每隔 $gap 米栽一棵，一共栽了 $trees 棵（两端都栽）。这条小路长多少米？',
        solutionSteps: [
          '两端都栽时，间隔数比树的棵数少 1。',
          '所以间隔数是 $trees − 1 = ${trees - 1} 个。',
          '每个间隔 $gap 米，总长 = ${trees - 1} × $gap = $len 米。',
          '记住这句口诀：两端都栽，棵数 = 间隔数 + 1。',
        ],
        answer: QuizAnswer(display: '$len', value: len.toDouble(), unit: '米'),
        kind: 'interval',
        difficulty: 4,
      );
    } else if (which == 1) {
      final len = gap * trees;
      return QuizQuestion(
        id: 'iv1-$trees-$gap',
        kpPath: Util.kpPath(c, '植树'),
        kpCode: Util.kpCode(c, '植树'),
        grade: c.grade,
        stem: '一条小路长 $len 米，在一边每隔 $gap 米栽一棵树，两端都栽，一共要栽多少棵？',
        solutionSteps: [
          '先算有多少个间隔：$len ÷ $gap = $trees 个。',
          '两端都栽：棵数 = 间隔数 + 1 = ${trees + 1} 棵。',
          '这一步最容易漏加 1。可以在纸上画 3 棵树看看：有 2 个间隔。',
        ],
        answer: QuizAnswer(display: '${trees + 1}', value: (trees + 1).toDouble(), unit: '棵'),
        kind: 'interval',
        difficulty: 4,
      );
    }
    // 锯木头：次数和段数的关系和植树刚好相反
    final pieces = c.ri(3, 9);
    final minutes = c.ri(2, 5);
    final total = (pieces - 1) * minutes;
    return QuizQuestion(
      id: 'iv2-$pieces-$minutes',
      kpPath: Util.kpPath(c, '植树'),
      kpCode: Util.kpCode(c, '植树'),
      grade: c.grade,
      stem: '把一根木头锯成 $pieces 段，每锯一次要 $minutes 分钟，一共要多少分钟？',
      solutionSteps: [
        '锯成 $pieces 段，只需要锯 ${pieces - 1} 次（锯最后一下就成两段了）。',
        '所以总时间 = ${pieces - 1} × $minutes = $total 分钟。',
        '和植树一样：这里是"点比间隔少 1"，画图最清楚。',
      ],
      answer: QuizAnswer(display: '$total', value: total.toDouble(), unit: '分钟'),
      kind: 'interval',
      difficulty: 4,
    );
  }

  // ignore: comment_references
  /// 求一个数的几分之几：闸门是结果必须为整数。
  static QuizQuestion fractionOf(_Ctx c) {
    final den = [3, 4, 5, 6, 8][c.rnd.nextInt(5)];
    final q = c.ri(3, 12);
    final total = den * q;
    final num_ = c.ri(1, den - 1);
    final partTimes = num_ * q;
    // 闸门：total × num/den 必须整除
    if ((total * num_) % den != 0 || partTimes == 0) return fractionOf(c);

    return QuizQuestion(
      id: 'frac-$total-$num_-$den',
      kpPath: Util.kpPath(c, '分数的意义'),
      kpCode: Util.kpCode(c, '分数的意义'),
      grade: c.grade,
      stem: '一本书有 $total 页，小明第一天看了全书的 $num_/$den，他第一天看了多少页？',
      solutionSteps: [
        '求一个数的几分之几，用这个数 ÷ 分母 × 分子。',
        '把 $total 平均分成 $den 份：$total ÷ $den = $q 页。',
        '取其中的 $num_ 份：$q × $num_ = $partTimes 页。',
        '答：第一天看了 $partTimes 页。',
      ],
      answer: QuizAnswer(display: '$partTimes', value: partTimes.toDouble(), unit: '页'),
      kind: 'fractionOf',
      difficulty: 3,
    );
  }
}

// ════════════════════ 工具 ════════════════════

class Util {
  /// 知识点标签。**不印别的年级的前缀**。
  ///
  /// `KnowledgeIndex.match` 在当前年级找不到同名考点时会退到"最近年级"
  /// （A12 的年级优先匹配留下的保底），于是三年级卷子上会冒出
  /// 「五上 · 数学广角 · 植树问题」这种标签 —— 家长看到的就是"年级串了"。
  /// 间隔问题、购物这类题型在本 App 里是按年级池注册的（三年级就有），
  /// 但它们在课标里的编码挂在别的年级；这种时候只印考点名，不印年级前缀。
  static String kpPath(_Ctx c, String name) {
    final p = c.index.match(knowledgePoint: name, grade: c.grade).point;
    if (p == null) return name;
    if (p.grade != c.grade) return p.name.isNotEmpty ? p.name : name;
    return p.path;
  }

  /// 考点编码。跨年级匹配到的不算数 —— 宁可留空，也不把三年级这道题
  /// 记到五上的编码上去（统计会串）。
  static String? kpCode(_Ctx c, String name) {
    final p = c.index.match(knowledgePoint: name, grade: c.grade).point;
    if (p == null) return null;
    return p.grade == c.grade ? p.code : null;
  }

  static bool anyCarry(int a, int b) {
    var x = a;
    var y = b;
    var carry = false;
    while (x > 0 || y > 0) {
      final ok = x % 10 + y % 10 + (carry ? 1 : 0) >= 10;
      carry = ok || x % 10 + y % 10 + (carry ? 1 : 0) >= 10;
      if (ok) return true;
      x ~/= 10;
      y ~/= 10;
    }
    return false;
  }

  static bool anyBorrow(int a, int b) {
    var x = a;
    var y = b;
    while (x > 0 && y > 0) {
      if (x % 10 < y % 10) return true;
      x ~/= 10;
      y ~/= 10;
    }
    return false;
  }

  /// 数字转字符串：12.0 → "12"，12.50 → "12.5"
  static String n(double v) {
    if ((v - v.roundToDouble()).abs() < 1e-9) return v.round().toString();
    final s = v.toStringAsFixed(2);
    return s.replaceAll(RegExp(r'0+$'), '').replaceAll(RegExp(r'\.$'), '');
  }
}

/// 给 UI 用：列出某年级的知识点（单元 → 考点）。
///
/// 同一单元可能在上下学期各出现一次，用 domain+单元名去重后，
/// 把两个学期的考点合并展示，避免家长看到两个同名条目。
class KnowledgeTree {
  static List<KnowledgeUnit> unitsOf(KnowledgeIndex index, int grade) {
    final seen = <String, KnowledgeUnit>{};
    for (final u in index.units) {
      if (u.grade != grade) continue;
      final key = '${u.domain.code}-${u.name}';
      final prev = seen[key];
      if (prev == null) {
        seen[key] = u;
      } else if (prev.semester != u.semester) {
        seen[key] = KnowledgeUnit(
          grade: u.grade,
          semester: prev.semester,
          domain: u.domain,
          unitNo: prev.unitNo,
          name: u.name,
          points: [...prev.points, ...u.points],
        );
      }
    }
    final out = seen.values.toList()..sort((a, b) => a.unitNo.compareTo(b.unitNo));
    return out;
  }
}
