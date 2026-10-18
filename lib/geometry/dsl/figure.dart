import '../../core/pt.dart';
import '../../core/rational.dart';

/// ────────────────────────────────────────────────────────────
/// 语义几何 DSL
///
/// 铁律：**DSL 里不允许出现任何坐标**。
/// 模型只声明数学关系（"半径 3"、"直角边 6 和 4"、"三边 3/4/5"），
/// 坐标由本地求解器用解析公式算出来，答案也由本地算出来。
///
/// 这是整套架构能同时做到「自动出变体」和「答案永不错」的唯一原因。
/// ────────────────────────────────────────────────────────────

/// 小学 1–6 年级几何图形全集。
/// 刻意做成枚举而不是自由 DSL：把模型的输出约束进有限集合，
/// 远比让它自由发挥再纠错容易 —— 这是本方案的核心取舍。
enum FigureType {
  // 平面基本图形
  rect('长方形'),
  square('正方形'),
  triangleRight('直角三角形'),
  triangleGeneral('一般三角形'),
  parallelogram('平行四边形'),
  trapezoid('梯形'),

  // 圆类
  circle('圆'),
  semicircle('半圆'),
  sector('扇形'),
  ring('圆环'),

  // 组合图形
  compositeRectSemicircle('矩形加半圆'),
  compositeSquareCircle('正方形内切圆'),
  latticePolygon('格点不规则多边形'),
  leafEstimate('不规则曲线估面积'),

  // 立体与展开
  cubeNet('正方体展开图'),
  cuboidOblique('长方体斜二测图'),
  cylinder('圆柱'),
  cone('圆锥'),

  // 统计图表
  grid('方格纸'),
  barChart('条形统计图'),
  lineChart('折线统计图'),
  pieChart('扇形统计图');

  const FigureType(this.label);
  final String label;

  static FigureType? fromName(String? s) {
    if (s == null) return null;
    for (final t in values) {
      if (t.name == s || t.label == s) return t;
    }
    return null;
  }
}

enum LineStyle { solid, dashed, thin, bold }

enum FillStyle { none, shade, hatch }

/// 模型给出的图形声明。
class FigureSpec {
  final FigureType type;

  /// 语义参数（只有数学量，没有坐标）。如 {'w':6,'h':4}。
  final Map<String, num> params;

  /// 数组型数值参数（统计图的数据序列）。如 {'values':[3,5,4]}。
  final Map<String, List<num>> lists;

  /// 数组型文本参数（统计图的类别名）。如 {'labels':['苹果','香蕉']}。
  final Map<String, List<String>> strs;

  /// 长度单位，如 'cm'。
  final String unit;

  /// 是否画方格纸（格点题必须画）。
  final bool grid;

  /// 方格边长（数学单位）。
  final num gridStep;

  /// 是否对指定区域做阴影填充（"求阴影部分面积"类题型）。
  final bool shade;

  /// 覆盖默认标注文字，key 见各 builder 约定。
  final Map<String, String> text;

  final int grade;

  const FigureSpec({
    required this.type,
    this.params = const {},
    this.lists = const {},
    this.strs = const {},
    this.unit = 'cm',
    this.grid = false,
    this.gridStep = 1,
    this.shade = false,
    this.text = const {},
    this.grade = 3,
  });

  num p(String key, num fallback) => params[key] ?? fallback;
  num? pOrNull(String key) => params[key];
  String t(String key, String fallback) => text[key] ?? fallback;

  List<num> list(String key) => lists[key] ?? const [];
  List<String> strList(String key) => strs[key] ?? const [];

  FigureSpec copyWith({
    FigureType? type,
    Map<String, num>? params,
    String? unit,
    bool? grid,
    num? gridStep,
    bool? shade,
    Map<String, String>? text,
    int? grade,
  }) =>
      FigureSpec(
        type: type ?? this.type,
        params: params ?? this.params,
        unit: unit ?? this.unit,
        grid: grid ?? this.grid,
        gridStep: gridStep ?? this.gridStep,
        shade: shade ?? this.shade,
        text: text ?? this.text,
        grade: grade ?? this.grade,
      );

  factory FigureSpec.fromJson(Map<String, Object?> m) {
    final type = FigureType.fromName(m['type'] as String?);
    if (type == null) {
      throw FormatException('未知图形类型: ${m['type']}');
    }
    final rawParams = m['params'];
    final params = <String, num>{};
    if (rawParams is Map) {
      rawParams.forEach((k, v) {
        if (v is num) params[k.toString()] = v;
      });
    }
    final rawText = m['text'];
    final text = <String, String>{};
    if (rawText is Map) {
      rawText.forEach((k, v) {
        if (v != null) text[k.toString()] = v.toString();
      });
    }
    final lists = <String, List<num>>{};
    final rawLists = m['lists'];
    if (rawLists is Map) {
      rawLists.forEach((k, v) {
        if (v is List) lists[k.toString()] = v.whereType<num>().toList();
      });
    }
    final strs = <String, List<String>>{};
    final rawStrs = m['strs'];
    if (rawStrs is Map) {
      rawStrs.forEach((k, v) {
        if (v is List) strs[k.toString()] = v.map((e) => e.toString()).toList();
      });
    }
    return FigureSpec(
      type: type,
      params: params,
      lists: lists,
      strs: strs,
      unit: (m['unit'] as String?) ?? 'cm',
      grid: (m['grid'] as bool?) ?? false,
      gridStep: (m['gridStep'] as num?) ?? 1,
      shade: (m['shade'] as bool?) ?? false,
      text: text,
      grade: (m['grade'] as int?) ?? 3,
    );
  }

  Map<String, Object?> toJson() => {
        'type': type.name,
        'params': params,
        'unit': unit,
        'grid': grid,
        'gridStep': gridStep,
        'shade': shade,
        'text': text,
        'grade': grade,
      };
}

/// ────────────────────────────────────────────────────────────
/// 求解产物：FigureScene（渲染器消费的唯一输入）
/// 屏幕 CustomPainter 与 PDF PdfGraphics 共用这一份数据，写两个渲染器。
/// ────────────────────────────────────────────────────────────

sealed class Shape {}

class SLine extends Shape {
  final Pt a;
  final Pt b;
  final LineStyle style;
  SLine(this.a, this.b, [this.style = LineStyle.solid]);
}

class SPolyline extends Shape {
  final List<Pt> pts;
  final bool closed;
  final LineStyle style;
  final FillStyle fill;
  SPolyline(this.pts, {this.closed = false, this.style = LineStyle.solid, this.fill = FillStyle.none});
}

class SCircle extends Shape {
  final Pt c;
  final double r;
  final LineStyle style;
  final FillStyle fill;
  SCircle(this.c, this.r, {this.style = LineStyle.solid, this.fill = FillStyle.none});
}

/// 椭圆（立体图形的透视圆：圆柱上下底、圆锥底面）。
class SEllipse extends Shape {
  final Pt c;
  final double rx;
  final double ry;
  final LineStyle style;
  final FillStyle fill;
  SEllipse(this.c, this.rx, this.ry, {this.style = LineStyle.solid, this.fill = FillStyle.none});
}

/// 圆弧 / 扇形（start、sweep 用弧度，逆时针为正）。
class SArc extends Shape {
  final Pt c;
  final double r;
  final double start;
  final double sweep;
  final bool closedToCenter; // true = 扇形（两条半径 + 弧）
  final FillStyle fill;
  final LineStyle style;
  SArc(this.c, this.r, this.start, this.sweep,
      {this.closedToCenter = false, this.fill = FillStyle.none, this.style = LineStyle.solid});
}

/// 三次贝塞尔段（树叶等不规则曲线）。
class CubicSeg {
  final Pt c1;
  final Pt c2;
  final Pt p;
  const CubicSeg(this.c1, this.c2, this.p);
}

class SPath extends Shape {
  final Pt start;
  final List<CubicSeg> segs;
  final bool closed;
  final FillStyle fill;
  SPath(this.start, this.segs, {this.closed = false, this.fill = FillStyle.none});
}

/// 直角标记（那个小方块）。
class SRightAngle extends Shape {
  final Pt at;
  final Pt dir1;
  final Pt dir2;
  final double size;
  SRightAngle(this.at, this.dir1, this.dir2, {this.size = 0.35});
}

enum LabelKind { point, length, area, angle, note }

class PlacedLabel {
  final Pt at;
  final String text;
  final LabelKind kind;

  /// 文本相对锚点的偏移方向（用于避让）。
  final Pt offsetDir;

  PlacedLabel(this.at, this.text, {this.kind = LabelKind.note, this.offsetDir = Pt.zero});
}

class FigureScene {
  final List<Shape> shapes;
  final List<PlacedLabel> labels;

  /// 顶点小圆点。
  final List<Pt> dots;

  /// 图形本体（不含标注文字）的数学坐标包围盒。
  final Box2 extent;

  /// 本地算出的真答案（面积/周长/体积……）。
  /// 图形与数字是一体的：变体换数字后，答案必须随之更新，所以 facts 与 scene 必须同源同生。
  final FigureFacts facts;

  const FigureScene({
    required this.shapes,
    required this.labels,
    required this.dots,
    required this.extent,
    this.facts = const FigureFacts({}),
  });

  /// 含标注后的包围盒，渲染器据此做等比缩放。
  Box2 get paddedExtent => extent.pad(0.8);
}

/// ────────────────────────────────────────────────────────────
/// 计算结果（答案由本地算，不由模型给）
/// ────────────────────────────────────────────────────────────

/// 单位码 → 中文单位名。
/// 答案是要给孩子和家长看的，不能出现"平方cm"这种半成品。
String unitName(String code) {
  switch (code.toLowerCase()) {
    case 'cm':
      return '厘米';
    case 'mm':
      return '毫米';
    case 'dm':
      return '分米';
    case 'm':
      return '米';
    case 'km':
      return '千米';
    case 'g':
      return '克';
    case 'kg':
      return '千克';
    case 't':
      return '吨';
    case 's':
      return '秒';
    case 'min':
      return '分';
    case 'h':
      return '时';
    case 'yuan':
    case '元':
      return '元';
    default:
      return code;
  }
}

/// 一个带展示形态的量。
/// 小学阶段圆的答案常保留 π（"12π 平方厘米"），
/// 所以既要能给出精确形态，也要能给出小数近似。
class Quantity {
  /// 无 π 时的精确有理数；含 π 时为 null。
  final Rational? exact;

  /// 含 π 时的精确形态，如 "12π"；否则 null。
  final String? withPi;

  /// 小数近似（用于排序、比较、以及带 π 时的取值）。
  final double approx;

  final String unit;

  const Quantity({this.exact, this.withPi, required this.approx, this.unit = ''});

  factory Quantity.num(Rational v, {String unit = ''}) =>
      Quantity(exact: v, approx: v.toDouble(), unit: unitName(unit));

  factory Quantity.pi(Rational coefficient, {String unit = ''}) {
    String coefStr;
    if (coefficient == Rational.one) {
      coefStr = '';
    } else if (coefficient == Rational.zero) {
      coefStr = '0';
    } else {
      coefStr = coefficient.toString();
    }
    return Quantity(
      withPi: '${coefStr}π',
      approx: coefficient.toDouble() * 3.141592653589793,
      unit: unitName(unit),
    );
  }

  /// 展示串：优先精确形态（含 π），其次有理数，最后小数。
  String get display {
    final head = withPi ?? exact?.toString() ?? _fmt(approx);
    return unit.isEmpty ? head : '$head $unit';
  }

  /// 用于校验比对的小数（容差比较）。
  bool approxEquals(double other, {double eps = 1e-6}) => (approx - other).abs() < eps;

  static String _fmt(double v) {
    if ((v - v.roundToDouble()).abs() < 1e-9) return v.round().toString();
    final s = v.toStringAsFixed(2);
    return s.replaceAll(RegExp(r'0+$'), '').replaceAll(RegExp(r'\.$'), '');
  }

  @override
  String toString() => display;
}

/// 图形自带的"真答案"。变体题生成后直接读它，不需要模型参与。
class FigureFacts {
  final Map<String, Quantity> values;

  const FigureFacts(this.values);

  Quantity? operator [](String key) => values[key];

  Map<String, Object?> toJson() => {for (final e in values.entries) e.key: e.value.display};
}
