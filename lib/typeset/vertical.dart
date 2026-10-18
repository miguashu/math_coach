/// 竖式排版器。
///
/// 小学阶段真正高频、且没有任何现成库能处理的是竖式、脱式、带余除法、单位换算的**版式**。
/// 竞品几乎都没做，所以它会成为体验上最有辨识度的差异点。
///
/// 设计：这里只产出「网格模型」（纯 Dart，不依赖任何渲染框架），
/// 屏幕端用 CustomPainter 画、PDF 端用 PdfGraphics 画，共用同一份模型。
library;

/// 单元格角色（决定字号与颜色）。
enum VRole { digit, carry, operator, result, remainder, note }

class VCell {
  final String text;
  final VRole role;

  const VCell(this.text, this.role);

  bool get isEmpty => text.isEmpty;
}

/// 竖式网格模型。grid[row][col]，col 越大越靠右（个位在最右）。
class VerticalLayout {
  final List<List<VCell?>> grid;

  /// 在第 row 行下方画横线（教材里的"等号横线"）。
  final Set<int> rulesAfter;

  /// 除法竖式的"厂"形包围：非空时表示这是除法。
  final int? divisorCol;

  final String kind;

  /// 给孩子看的分步话术。
  final List<String> steps;

  const VerticalLayout({
    required this.grid,
    required this.rulesAfter,
    required this.kind,
    this.divisorCol,
    this.steps = const [],
  });

  int get rows => grid.length;
  int get cols => grid.isEmpty ? 0 : grid[0].length;

  VCell? at(int row, int col) {
    if (row < 0 || row >= rows) return null;
    if (col < 0 || col >= cols) return null;
    return grid[row][col];
  }

  /// 把网格导出成纯文本（便于单测断言与调试）。
  String toText() {
    final buf = StringBuffer();
    for (var r = 0; r < rows; r++) {
      for (var c = 0; c < cols; c++) {
        buf.write(at(r, c)?.text ?? ' ');
      }
      buf.writeln();
      if (rulesAfter.contains(r)) {
        buf.writeln('-' * cols);
      }
    }
    return buf.toString();
  }
}

class VerticalTypeset {
  /// 加法竖式（含进位小字）。
  ///
  /// [withAnswer] 为 false 时只排题面：进位小字和结果行留空（行列结构不变，
  /// 横线照画）——练习页作答前、导出试卷时都用这个形态，
  /// 否则竖式把答案印在题面上，题就白出了。
  static VerticalLayout add(int a, int b, {bool withAnswer = true}) {
    final sa = a.toString();
    final sb = b.toString();
    final sr = (a + b).toString();
    final width = _max([sa.length, sb.length, sr.length]);
    final cols = width + 1; // 左侧留一列给运算符

    final da = _digits(a);
    final db = _digits(b);
    final dr = _digits(a + b);

    // 进位：第 i 位相加产生的进位，标记在第 i+1 位上方
    final carries = <int>[];
    var carry = 0;
    for (var i = 0; i < width; i++) {
      final x = i < da.length ? da[i] : 0;
      final y = i < db.length ? db[i] : 0;
      final sum = x + y + carry;
      carry = sum >= 10 ? 1 : 0;
      carries.add(carry);
    }

    final g = _blank(4, cols);
    // row0：进位小字（写在产生进位的那一位的左边一列的正上方）
    if (withAnswer) {
      for (var i = 0; i < carries.length; i++) {
        if (carries[i] == 1) {
          final col = cols - 1 - (i + 1);
          if (col >= 0) g[0][col] = VCell('${carries[i]}', VRole.carry);
        }
      }
    }
    _placeRight(g[1], da, cols, VRole.digit);
    g[2][cols - 1 - sb.length] = const VCell('+', VRole.operator);
    _placeRight(g[2], db, cols, VRole.digit);
    if (withAnswer) _placeRight(g[3], dr, cols, VRole.result);

    return VerticalLayout(
      grid: g,
      rulesAfter: {2},
      kind: 'add',
      steps: [
        '先算个位：${da.isNotEmpty ? da[0] : 0} 加 ${db.isNotEmpty ? db[0] : 0}${carries.isNotEmpty && carries[0] == 1 ? '，满十了，向十位进 1' : ''}。',
        '再算十位，别忘了把进上来的 1 加回去。',
        '结果是 ${a + b}。',
      ],
    );
  }

  /// 减法竖式（含退位小字）。[withAnswer] 同 [add]。
  static VerticalLayout sub(int a, int b, {bool withAnswer = true}) {
    if (a < b) {
      throw ArgumentError('小学阶段暂不支持负数结果：$a − $b');
    }
    final sb = b.toString();
    final sr = (a - b).toString();
    final width = _max([a.toString().length, sb.length, sr.length]);
    final cols = width + 1;

    final da = _digits(a);
    final db = _digits(b);
    final dr = _digits(a - b);

    // 借位标记：第 i 位不够减时需要向高位借 1
    final borrows = <int>[];
    var borrow = 0;
    for (var i = 0; i < width; i++) {
      final x = i < da.length ? da[i] : 0;
      final y = i < db.length ? db[i] : 0;
      final need = x - borrow < y;
      borrows.add(need ? 1 : 0);
      borrow = need ? 1 : 0;
    }

    final g = _blank(4, cols);
    for (var i = 0; i < borrows.length; i++) {
      if (withAnswer && borrows[i] == 1) {
        final col = cols - 1 - (i + 1);
        if (col >= 0) g[0][col] = const VCell('·', VRole.carry);
      }
    }
    _placeRight(g[1], da, cols, VRole.digit);
    g[2][cols - 1 - sb.length] = const VCell('−', VRole.operator);
    _placeRight(g[2], db, cols, VRole.digit);
    if (withAnswer) _placeRight(g[3], dr, cols, VRole.result);

    return VerticalLayout(
      grid: g,
      rulesAfter: {2},
      kind: 'sub',
      steps: [
        '从个位开始减，${da.isNotEmpty ? da[0] : 0} 减 ${db.isNotEmpty ? db[0] : 0}。',
        borrows.isNotEmpty && borrows[0] == 1 ? '个位不够减，向十位借 1 当 10。' : '够减，直接算。',
        '结果是 ${a - b}。',
      ],
    );
  }

  /// 乘法竖式：支持多位数乘多位数，逐位写出部分积。
  /// [withAnswer] 为 false 时部分积与积都留空（这两行就是孩子要填的作业）。
  static VerticalLayout mul(int a, int b, {bool withAnswer = true}) {
    final sa = a.toString();
    final sb = b.toString();
    final product = a * b;
    final sp = product.toString();

    final db = _digits(b);
    // 部分积（从个位开始）
    final partials = <int>[];
    for (var i = 0; i < db.length; i++) {
      partials.add(a * db[i]);
    }

    var width = _max([sa.length, sb.length + 1, sp.length]);
    for (var i = 0; i < partials.length; i++) {
      width = _max([width, partials[i].toString().length + i]);
    }
    final cols = width + 1;

    // 行数：被乘数、乘数、(横线)、[每个部分积、(横线)]、积
    // 一位数乘数时，部分积就是积本身，不能重复画两行。
    final n = partials.length;
    final rowCount = 2 + (n > 1 ? n + 1 : 1);
    final g = _blank(rowCount, cols);

    _placeRight(g[0], _digits(a), cols, VRole.digit);
    g[1][cols - 1 - sb.length] = const VCell('×', VRole.operator);
    _placeRight(g[1], db, cols, VRole.digit);

    final rules = <int>{1};
    if (n > 1) {
      var r = 2;
      for (var i = 0; i < n; i++) {
        if (withAnswer) {
          _placeRight(g[r], _digits(partials[i]), cols - i, VRole.digit);
        }
        r++;
      }
      rules.add(r - 1); // 最后一个部分积下方画横线
      if (withAnswer) _placeRight(g[r], _digits(product), cols, VRole.result);
    } else {
      if (withAnswer) _placeRight(g[2], _digits(product), cols, VRole.result);
    }

    return VerticalLayout(
      grid: g,
      rulesAfter: rules,
      kind: 'mul',
      steps: [
        '先用乘数的个位去乘被乘数，得 ${partials.isNotEmpty ? partials[0] : 0}。',
        if (partials.length > 1) '再用十位去乘，得 ${partials[1]}，注意要向左错一位写。',
        if (partials.length > 1) '最后把两次的结果加起来。',
        '结果是 $product。',
      ],
    );
  }

  /// 带余除法（长除法）。
  ///
  /// 返回结构化步骤，渲染器据此画"厂"形竖式。
  /// [withAnswer] 为 false 时商与余数置为 null 的展示形态由渲染层判断
  /// （这里直接给 [LongDivision.withAnswer] = false，数值仍保留供批改用，
  /// 渲染器见到该标记就不画商/余数/中间步骤）。
  static LongDivision div(int a, int b, {bool withAnswer = true}) {
    if (b == 0) throw ArgumentError('除数不能为 0');
    final q = a ~/ b;
    final r = a % b;

    // 逐位试商，记录每一步的"落下—乘—减"
    final digits = a.toString().split('').map(int.parse).toList();
    final steps = <DivStep>[];
    var cur = 0;
    var quotientDigits = <int>[];

    for (final d in digits) {
      cur = cur * 10 + d;
      final digit = cur ~/ b;
      final product = digit * b;
      final rem = cur - product;
      quotientDigits.add(digit);
      steps.add(DivStep(bringDown: cur, quotientDigit: digit, product: product, remainder: rem));
      cur = rem;
    }

    // 去掉商的前导零
    while (quotientDigits.length > 1 && quotientDigits.first == 0) {
      quotientDigits = quotientDigits.sublist(1);
      steps.removeAt(0);
    }

    return LongDivision(
      dividend: a,
      divisor: b,
      quotient: q,
      remainder: r,
      steps: steps,
      display: r == 0 ? '$a ÷ $b = $q' : '$a ÷ $b = $q …… $r',
      withAnswer: withAnswer,
    );
  }

  // ── 工具 ────────────────────────────────────────────────

  /// 返回低位在前的数字数组（index 0 = 个位）。
  static List<int> _digits(int v) {
    final abs = v.abs();
    if (abs == 0) return [0];
    final out = <int>[];
    var t = abs;
    while (t > 0) {
      out.add(t % 10);
      t ~/= 10;
    }
    return out;
  }

  static void _placeRight(List<VCell?> row, List<int> digitsLowFirst, int cols, VRole role) {
    for (var i = 0; i < digitsLowFirst.length; i++) {
      final col = cols - 1 - i;
      if (col >= 0 && col < row.length) {
        row[col] = VCell('${digitsLowFirst[i]}', role);
      }
    }
  }

  static List<List<VCell?>> _blank(int rows, int cols) =>
      List.generate(rows, (_) => List<VCell?>.filled(cols, null));

  static int _max(List<int> xs) => xs.reduce((a, b) => a > b ? a : b);
}

/// 长除法的结构化结果。
class LongDivision {
  final int dividend;
  final int divisor;
  final int quotient;
  final int remainder;
  final List<DivStep> steps;
  final String display;

  /// false = 只排题面：渲染器不画商、余数和中间步骤（练习/试卷形态）。
  /// 数值字段仍然完整，批改逻辑照常用它们。
  final bool withAnswer;

  const LongDivision({
    required this.dividend,
    required this.divisor,
    required this.quotient,
    required this.remainder,
    required this.steps,
    required this.display,
    this.withAnswer = true,
  });

  bool get isExact => remainder == 0;
}

class DivStep {
  /// 当前参与运算的数（上一位余数落下来之后）。
  final int bringDown;

  /// 这一位上试的商。
  final int quotientDigit;

  /// 商 × 除数。
  final int product;

  /// 相减后的余数。
  final int remainder;

  const DivStep({
    required this.bringDown,
    required this.quotientDigit,
    required this.product,
    required this.remainder,
  });
}
