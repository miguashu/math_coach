import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import 'vertical.dart';

/// 竖式的 PDF 渲染：逐格定位绘制，保证数位严格对齐。
///
/// 为什么不能用文本直接排：中文字体里的数字通常不是等宽的，
/// 直接用字符串排版会导致数位错位 —— 而"数位对齐"恰恰是竖式的全部意义。
///
/// 注意这里用的是底层 PdfFont（PdfGraphics 需要它），
/// 而不是 widgets 层的 pw.Font。
class VerticalPdf {
  final PdfFont font;
  final PdfFont fontBold;
  final PdfColor color;
  final PdfColor carryColor;

  const VerticalPdf({
    required this.font,
    required this.fontBold,
    this.color = PdfColors.black,
    this.carryColor = PdfColors.red700,
  });

  pw.Widget render(VerticalLayout layout, {double fontSize = 13}) {
    final cellW = fontSize * 1.15;
    final cellH = fontSize * 1.5;
    final w = layout.cols * cellW;
    final h = layout.rows * cellH;

    return pw.SizedBox(
      width: w,
      height: h,
      child: pw.CustomPaint(
        size: PdfPoint(w, h),
        painter: (PdfGraphics g, PdfPoint size) {
          double cx(int col) => col * cellW + cellW / 2;
          // 排版网格按 y 向下设计（row 0 在最上），而 PdfGraphics 原点在左下、
          // y 向上 —— 必须翻转，否则竖式整体上下颠倒（结果行跑到最上面）。
          double cy(int row) => h - (row * cellH + cellH / 2);

          void put(String text, double x, double y,
              {required PdfFont f, required double sz, PdfColor? col}) {
            final m = f.stringMetrics(text) * sz;
            g.setFont(f, sz);
            g.setFillColor(col ?? color);
            g.drawString(f, sz, text, x - m.width / 2, y - sz * 0.36);
          }

          for (var r = 0; r < layout.rows; r++) {
            for (var c = 0; c < layout.cols; c++) {
              final cell = layout.at(r, c);
              if (cell == null || cell.text.isEmpty) continue;
              final isCarry = cell.role == VRole.carry;
              final f = (cell.role == VRole.result || cell.role == VRole.operator) ? fontBold : font;
              put(cell.text, cx(c), cy(r),
                  f: f, sz: isCarry ? fontSize * 0.6 : fontSize, col: isCarry ? carryColor : null);
            }
            // 横线：必须覆盖整式宽度
            // 注意：pdf 包的 drawLine 只做 moveTo+lineTo，不会自动描边，
            // 必须手动 strokePath()，否则线不显示（且路径会累积到后续绘制里）。
            if (layout.rulesAfter.contains(r)) {
              g.setStrokeColor(color);
              g.setLineWidth(0.8);
              g.drawLine(0, h - ((r + 1) * cellH + 1), w, h - ((r + 1) * cellH + 1));
              g.strokePath();
            }
          }
        },
      ),
    );
  }

  /// 长除法（"厂"形竖式）。
  pw.Widget renderLongDivision(LongDivision d, {double fontSize = 13}) {
    final cellH = fontSize * 1.5;
    final rows = 2 + d.steps.length * 2;
    final h = rows * cellH + 16; // 顶部多留 8pt 给商的上伸部（翻转后需要）
    const w = 170.0;
    const left = 6.0;
    const inside = left + 34.0; // 被除数起始 x

    return pw.SizedBox(
      width: w,
      height: h,
      child: pw.CustomPaint(
        size: PdfPoint(w, h),
        painter: (PdfGraphics g, PdfPoint size) {
          // 设计坐标 y 向下，PdfGraphics 原点在左下 y 向上 —— 统一翻转
          double Y(double yDesign) => h - yDesign - 8;

          void put(String text, double x, double y,
              {bool bold = false, double? sz, PdfColor? col}) {
            final f = bold ? fontBold : font;
            final s = sz ?? fontSize;
            g.setFont(f, s);
            g.setFillColor(col ?? color);
            g.drawString(f, s, text, x, Y(y));
          }

          // 商（写在横线上方）。题面形态（withAnswer=false）不画商/余数/中间步骤
          final showAnswer = d.withAnswer;
          if (showAnswer) put('${d.quotient}', left + 14, 2, bold: true);

          // "厂"形：横线 + 左竖（横线要盖住整个被除数）
          final divText = '${d.dividend}';
          final divW = font.stringMetrics(divText).width * fontSize;
          g.setStrokeColor(color);
          g.setLineWidth(0.9);
          g.drawLine(left + 10, Y(cellH + cellH * 0.62), inside + divW + 8, Y(cellH + cellH * 0.62));
          g.drawLine(left + 10, Y(cellH + cellH * 0.62), left + 10, Y(cellH * 2.0));
          g.strokePath();

          // 除数（左侧）、被除数（厂内）
          put('${d.divisor}', left + 13, cellH + cellH * 0.68);
          put(divText, inside, cellH + cellH * 0.68);
          if (showAnswer && !d.isExact) {
            put('……${d.remainder}', inside + divW + 6, cellH + cellH * 0.68, sz: fontSize * 0.85);
          }

          // 逐步：乘积 + 相减横线 + 余数（设计坐标向下增长，翻转后视觉向下）
          var y = cellH * 2.1;
          for (final s in d.steps) {
            if (!showAnswer) break;
            final pText = '${s.product}';
            final pW = font.stringMetrics(pText).width * fontSize;
            final indent = inside + (divText.length - pText.length) * fontSize * 0.62;
            put(pText, indent, y);
            g.setStrokeColor(color);
            g.setLineWidth(0.8);
            g.drawLine(indent - 3, Y(y + cellH * 0.48), indent + pW + 4, Y(y + cellH * 0.48));
            g.strokePath();
            put('${s.remainder}', inside + (divText.length - '${s.remainder}'.length) * fontSize * 0.62,
                y + cellH * 0.55);
            y += cellH * 1.15;
          }
        },
      ),
    );
  }
}
