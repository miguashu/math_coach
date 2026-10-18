/// 题目与判分模型。
///
/// 两条硬规矩（方案里反复强调的）：
///   1) 答案 **本地算**，模型不许给数
///   2) 判分要宽容——"0.5" 和 ".5" 和 "0.50" 都算对，
///      但"单位写错"不算错字、也不算全对（单独提示）
library;

/// 一道题。
class QuizQuestion {
  /// 稳定 id：同参数同 id，便于去重与归档。
  final String id;

  /// 知识点（三级归类后的路径文案，如"数与代数 / 图形与几何 …"）
  final String kpPath;

  final String? kpCode;
  final int grade;

  /// 题干（可能含少量 HTML 换行，不含用户输入）
  final String stem;

  /// 分步讲解：每步一句话，像老师说话，不是算式罗列
  final List<String> solutionSteps;

  /// 最终答案
  final QuizAnswer answer;

  /// 配图（FigureScene → SVG），没有配图则为 null
  final String? figureSvg;

  /// 竖式（VerticalLayout / LongDivision → SVG）
  final String? verticalSvg;

  /// 题型标识，用于统计与去重
  final String kind;

  /// 难度 1..5
  final int difficulty;

  /// 几何题的原始 spec：导出 PDF 时要按 PDF 精度重新求解画图，
  /// 不能复用屏幕上的 SVG（那样打印会糊、也没法换版式）。
  final Map<String, Object?>? figureSpec;

  /// 竖式重放参数：导出 PDF 时用它按 PDF 排版器重画，
  /// 保证试卷上的竖式和孩子当时练的完全一致。
  final String? verticalKind;
  final List<int> verticalArgs;

  /// 题目来源：'local' = 本地模板题库（默认），'ai' = 模型现场生成。
  /// 界面据此显示"AI 新题"徽标，也让家长知道哪些题是新鲜出炉的。
  final String source;

  const QuizQuestion({
    required this.id,
    required this.kpPath,
    required this.stem,
    required this.solutionSteps,
    required this.answer,
    required this.kind,
    this.kpCode,
    required this.grade,
    this.figureSvg,
    this.verticalSvg,
    this.difficulty = 2,
    this.figureSpec,
    this.verticalKind,
    this.verticalArgs = const [],
    this.source = 'local',
  });

  bool get isAi => source == 'ai';

  Map<String, dynamic> toJson() => {
        'id': id,
        'kpPath': kpPath,
        'kpCode': kpCode,
        'grade': grade,
        'stem': stem,
        'steps': solutionSteps,
        'answer': answer.display,
        'figureSvg': figureSvg,
        'verticalSvg': verticalSvg,
        'kind': kind,
        'difficulty': difficulty,
        'source': source,
      };
}

/// 答案：展示文本 + 可接受写法 + 可数值比较时的值与容差。
class QuizAnswer {
  final String display;

  /// 数值答案（能比较时给出），单位已剥离
  final double? value;

  /// 数值容差
  final double tolerance;

  /// 单位（展示用；判分时自动剥离，不写也不算错，但会提示）
  final String unit;

  /// 额外的可接受文本写法（已规范化格式）
  final List<String> accepts;

  const QuizAnswer({
    required this.display,
    this.value,
    this.tolerance = 0.011,
    this.unit = '',
    this.accepts = const [],
  });

  /// 判断学生答案是否正确。
  ///
  /// 判分顺序：文本精确（规范化后）→ 可接受写法 → 数值容差。
  /// 这样 "9……2"、"9 …… 2"、"9余2" 都能判对，不会因为书写习惯被判错。
  bool check(String raw) {
    final u = QuizNormalize.raw(raw);
    if (u.isEmpty) return false;

    final expected = QuizNormalize.raw(display);
    if (u == expected) return true;

    for (final a in accepts) {
      if (u == QuizNormalize.raw(a)) return true;
    }

    // 剥离单位后 retry 一次
    final stripped = u.replaceAll(QuizNormalize._unitPattern, '');
    if (stripped.isNotEmpty && stripped == QuizNormalize.raw(display).replaceAll(
            QuizNormalize._unitPattern, '')) {
      return true;
    }

    if (value != null) {
      // 有余数的除法：display 形如 "8 …… 2"，规范化后是 "8…2"。
      // 学生只写商 "8" 时，上面的文本匹配会失败，但数值比较
      // |8 − 8| = 0 ≤ 容差，于是被判对 —— 等于默许"漏写余数"。
      // 可余数正是这个考点的全部意义（孩子最常错的就是"余数比除数大"
      // 和"忘了写余数"），所以这里要求答案带余数才给过。
      if (expected.contains('…') && !u.contains('…')) {
        return false;
      }
      final n = QuizNormalize.toNumber(u);
      if (n != null && (n - value!).abs() <= tolerance) return true;
    }
    return false;
  }
}

/// 答案规范化：把各种书写习惯归一到可比较的形式。
class QuizNormalize {
  /// 常见单位（面积/长度/货币等）词尾
  static final RegExp _unitPattern = RegExp(
      r'(平方厘米|平方分米|平方米|平方毫米|立方厘米|立方分米|立方米|'
      r'厘米|分米|毫米|米|千米|平米|克|千克|吨|毫升|升|元|角|分|'
      r'平方厘米?|cm²|cm\^2|m²|cm|m|km|kg|g|个|人|本|支|棵|朵|只|辆|盒|个)$');

  /// 全角→半角 + 去空格 + 统一省略号/运算符。
  static String raw(String s) {
    var t = s.trim().toLowerCase();
    const fullWidth = {
      '０': '0', '１': '1', '２': '2', '３': '3', '４': '4',
      '５': '5', '６': '6', '７': '7', '８': '8', '９': '9',
      '．': '.', '，': ',', '（': '(', '）': ')',
      '×': '*', '÷': '/', '＋': '+', '－': '-', '＝': '=',
      '％': '%', '／': '/', '。': '.',
    };
    fullWidth.forEach((k, v) => t = t.replaceAll(k, v));
    // 余数的各种写法：…… … .. 余 r
    t = t.replaceAllMapped(
        RegExp(r'(…{1,2}|\.\.\.\.?)\s*'), (m) => '…');
    t = t.replaceAllMapped(RegExp(r'余\s*'), (m) => '…');
    t = t.replaceAll(RegExp(r'\s+'), '');
    // 去掉千分位
    t = t.replaceAllMapped(RegExp(r'(\d),(\d{3})'), (m) => '${m[1]}${m[2]}');
    // 去掉数学符号包裹
    t = t.replaceAll(RegExp(r'[（）()\[\]【】]'), '');
    // 数字开头前导 +、- 0
    if (RegExp(r'^\+\d').hasMatch(t)) t = t.substring(1);
    // 0.50 → 0.5（去小数点后无意义的 0）
    if (t.contains('.')) {
      t = t.replaceAllMapped(RegExp(r'(\d+)(\.\d*?)0+$'), (m) => '${m[1]}${m[2]}');
      t = t.replaceAll(RegExp(r'\.$'), '');
      t = t.replaceAllMapped(RegExp(r'^(\+)0(\.\d)'), (m) => '0${m[2]}');
    }
    return t;
  }

  /// 提取数值（支持 3.14π、1/2、带分数 "2又1/3"、百分数）。
  static double? toNumber(String rawU) {
    var t = rawU;
    // 带余数/带单位的情形取前半部分
    t = t.replaceAll('…', ' ').split(' ').first.trim();
    t = t.replaceAll(RegExp(r'[a-z\u4e00-\u9fa5]+'), ''); // 去掉字母与汉字（含单位、π）
    t = t.trim();
    if (t.isEmpty) return null;

    double? frac;
    final mix = RegExp(r'^(\d+)又(\d+)/(\d+)$').firstMatch(t);
    if (mix != null) {
      final a = double.tryParse(mix.group(1)!);
      final b = double.tryParse(mix.group(2)!);
      final c = double.tryParse(mix.group(3)!);
      if (a == null || b == null || c == null || c == 0) return null;
      frac = a + b / c;
      return frac;
    }
    final f = RegExp(r'^(-?\d+)/(\d+)$').firstMatch(t);
    if (f != null) {
      final a = double.tryParse(f.group(1)!);
      final b = double.tryParse(f.group(2)!);
      if (a == null || b == null || b == 0) return null;
      return a / b;
    }
    if (RegExp(r'^-?\d+%$').hasMatch(t)) {
      return double.tryParse(t.replaceAll('%', ''))! / 100;
    }
    return double.tryParse(t);
  }
}
