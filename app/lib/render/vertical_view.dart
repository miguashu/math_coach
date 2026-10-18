/// 竖式 / 长除法的 Flutter Canvas 渲染。
///
/// 与 Web 的 vertical_svg.dart 是同一套坐标逻辑（Canvas 和 SVG 都是 y 向下，
/// 不需要翻转），差别只在最后落到不同后端 —— 数位对齐的语义只定义一次。
///
/// 每个字符单独定位而不是拼成一行文本：中文字体里数字通常不等宽，
/// 拼成文本必然错位，而**数位对齐就是竖式的全部意义**。
library;

import 'package:flutter/material.dart';
import 'package:math_coach/typeset/vertical.dart';

const double _kFontSize = 20;

/// 竖式（加减乘）。
class VerticalView extends StatelessWidget {
  final VerticalLayout layout;
  const VerticalView({super.key, required this.layout});

  @override
  Widget build(BuildContext context) {
    final cellW = _kFontSize * 1.25;
    final cellH = _kFontSize * 1.42;
    final w = layout.cols * cellW + 8;
    final h = layout.rows * cellH + 8;
    return SizedBox(
      width: w,
      height: h,
      child: CustomPaint(
        size: Size(w, h),
        painter: _VPainter(layout, cellW, cellH),
      ),
    );
  }
}

class _VPainter extends CustomPainter {
  final VerticalLayout layout;
  final double cellW;
  final double cellH;
  const _VPainter(this.layout, this.cellW, this.cellH);

  @override
  bool shouldRepaint(covariant _VPainter old) => old.layout != layout;

  @override
  void paint(Canvas canvas, Size size) {
    const ox = 4.0;
    const oy = 4.0;
    final line = Paint()
      ..color = const Color(0xFF1E293B)
      ..strokeWidth = 1.4;

    for (var r = 0; r < layout.rows; r++) {
      for (var c = 0; c < layout.cols; c++) {
        final cell = layout.at(r, c);
        if (cell == null || cell.text.isEmpty) continue;
        final isCarry = cell.role == VRole.carry;
        final x = ox + c * cellW + cellW / 2;
        var y = oy + r * cellH + cellH / 2;
        // 进位小字要往上抬一点，落在两行之间
        if (isCarry) y -= cellH * 0.28;

        final size = isCarry ? _kFontSize * 0.58 : _kFontSize;
        final color = isCarry ? const Color(0xFFDC2626) : const Color(0xFF1E293B);
        final weight =
            (cell.role == VRole.result || cell.role == VRole.operator) ? FontWeight.w700 : FontWeight.w500;

        final tp = TextPainter(
          text: TextSpan(
            text: cell.text,
            style: TextStyle(
              fontSize: size,
              color: color,
              fontWeight: weight,
              fontFamily: 'monospace',
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        tp.paint(canvas, Offset(x - tp.width / 2, y - tp.height / 2));
      }
      // 横线：必须覆盖整式宽度
      if (layout.rulesAfter.contains(r)) {
        final y = oy + (r + 1) * cellH - cellH * 0.18;
        canvas.drawLine(Offset(ox, y), Offset(size.width - ox, y), line);
      }
    }
  }
}

/// 长除法（"厂"形竖式）。
class LongDivisionView extends StatelessWidget {
  final LongDivision d;
  const LongDivisionView({super.key, required this.d});

  @override
  Widget build(BuildContext context) {
    final cellH = _kFontSize * 1.42;
    final rows = 2 + d.steps.length * 2;
    final h = rows * cellH + 16;
    return SizedBox(
      width: 210,
      height: h,
      child: CustomPaint(size: Size(210, h), painter: _DPainter(d, cellH)),
    );
  }
}

class _DPainter extends CustomPainter {
  final LongDivision d;
  final double cellH;
  const _DPainter(this.d, this.cellH);

  @override
  bool shouldRepaint(covariant _DPainter old) => old.d != d;

  void _text(Canvas canvas, String t, double x, double y,
      {double size = _kFontSize, Color color = const Color(0xFF1E293B), FontWeight w = FontWeight.w400}) {
    final tp = TextPainter(
      text: TextSpan(
        text: t,
        style: TextStyle(fontSize: size, color: color, fontWeight: w, fontFamily: 'monospace'),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, Offset(x - tp.width / 2, y - tp.height / 2));
  }

  @override
  void paint(Canvas canvas, Size size) {
    const left = 8.0;
    const inside = left + 40.0;
    final chW = _kFontSize * 0.62; // 等宽字宽估值
    final line = Paint()
      ..color = const Color(0xFF1E293B)
      ..strokeWidth = 1.4;
    final thinLine = Paint()
      ..color = const Color(0xFF1E293B)
      ..strokeWidth = 1.1;

    final divText = '${d.dividend}';
    final divW = divText.length * chW;

    // 题面形态（withAnswer=false）：只画"厂"形、除数、被除数，
    // 商/余数/中间步骤全部留给学生填。行高结构不变，批改后重放会显示完整版。
    final showAnswer = d.withAnswer;

    // 商（写在横线上方）
    if (showAnswer) {
      _text(canvas, '${d.quotient}', left + 18 + chW * 0.5, cellH * 0.5, w: FontWeight.w700);
    }

    // "厂"形：横线覆盖整个被除数，左竖向下
    final barY = cellH * 1.25;
    canvas.drawLine(Offset(left + 12, barY), Offset(inside + divW + 10, barY), line);
    canvas.drawLine(Offset(left + 12, barY), Offset(left + 12, cellH * 1.95), line);

    // 除数（左侧）、被除数（厂内）
    final baseY = cellH * 1.7;
    _text(canvas, '${d.divisor}', left + 15 + chW * 0.5, baseY);
    // 被除数左对齐：从 inside 开始
    final tpDiv = TextPainter(
      text: TextSpan(
        text: divText,
        style: const TextStyle(fontSize: _kFontSize, color: Color(0xFF1E293B), fontFamily: 'monospace'),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tpDiv.paint(canvas, Offset(inside, baseY - tpDiv.height / 2));
    if (showAnswer && !d.isExact) {
      _text(canvas, '……${d.remainder}', inside + divW + 8 + chW * 1.5, baseY,
          size: _kFontSize * 0.8, color: const Color(0xFF475569));
    }

    // 逐步：乘积 + 相减横线 + 余数
    var y = cellH * 2.5;
    for (final s in d.steps) {
      if (!showAnswer) break;
      final pText = '${s.product}';
      final pW = pText.length * chW;
      final indent = inside + (divText.length - pText.length) * chW;
      final tpP = TextPainter(
        text: TextSpan(
          text: pText,
          style: const TextStyle(fontSize: _kFontSize, color: Color(0xFF1E293B), fontFamily: 'monospace'),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tpP.paint(canvas, Offset(indent, y - tpP.height / 2));
      canvas.drawLine(Offset(indent - 3, y + cellH * 0.38), Offset(indent + pW + 4, y + cellH * 0.38), thinLine);

      final rText = '${s.remainder}';
      final rIndent = inside + (divText.length - rText.length) * chW;
      final tpR = TextPainter(
        text: TextSpan(
          text: rText,
          style: const TextStyle(fontSize: _kFontSize, color: Color(0xFF1E293B), fontFamily: 'monospace'),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tpR.paint(canvas, Offset(rIndent, y + cellH * 0.85 - tpR.height / 2));
      y += cellH * 1.15;
    }
  }
}
