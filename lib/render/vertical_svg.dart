/// 竖式的 SVG 渲染（屏幕/Web 端）。
///
/// 必须与 PDF 竖式是同一份 VerticalLayout 模型，只是后端不同 ——
/// 这样"数位对齐"的语义只定义一次，两个产物不会各跑一套。
///
/// SVG 的坐标原点在左上、y 向下，与排版网格天然一致，不需要翻转。
/// 每个字符单独用 <text> 定位（而不是拼成一行文本）：
/// 中文字体里数字通常不等宽，拼成文本必然错位，而数位对齐是竖式的全部意义。
library;

import '../typeset/vertical.dart';

class VerticalSvgRenderer {
  final double fontSize;

  const VerticalSvgRenderer({this.fontSize = 20});

  String render(VerticalLayout layout, {String idPrefix = 'v'}) {
    final cellW = fontSize * 1.25;
    final cellH = fontSize * 1.42;
    final w = layout.cols * cellW + 8;
    final h = layout.rows * cellH + 8;
    final ox = 4.0;
    final oy = 4.0;

    final buf = StringBuffer();
    buf.write('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${_n(w)} ${_n(h)}" '
        'width="${_n(w)}" height="${_n(h)}" class="vert-svg">');
    buf.write('<g font-family="ui-monospace, Consolas, monospace" '
        'font-size="$fontSize" text-anchor="middle" dominant-baseline="middle">');

    for (var r = 0; r < layout.rows; r++) {
      for (var c = 0; c < layout.cols; c++) {
        final cell = layout.at(r, c);
        if (cell == null || cell.text.isEmpty) continue;
        final x = ox + c * cellW + cellW / 2;
        final y = oy + r * cellH + cellH / 2;
        final isCarry = cell.role == VRole.carry;
        final weight = (cell.role == VRole.result || cell.role == VRole.operator) ? '700' : '500';
        final color = isCarry ? '#dc2626' : '#1e293b';
        final size = isCarry ? fontSize * 0.58 : fontSize;
        // 进位小字要往上抬一点，落在两行之间
        final dy = isCarry ? -cellH * 0.28 : 0.0;
        buf.write('<text x="${_n(x)}" y="${_n(y + dy)}" font-size="${_n(size)}" '
            'font-weight="$weight" fill="$color">${_esc(cell.text)}</text>');
      }
      if (layout.rulesAfter.contains(r)) {
        final y = oy + (r + 1) * cellH - cellH * 0.18;
        buf.write('<line x1="${_n(ox)}" y1="${_n(y)}" x2="${_n(w - ox)}" y2="${_n(y)}" '
            'stroke="#1e293b" stroke-width="1.4"/>');
      }
    }

    buf.write('</g></svg>');
    return buf.toString();
  }

  /// 长除法（"厂"形竖式）。
  String renderLongDivision(LongDivision d) {
    final cellH = fontSize * 1.42;
    final rows = 2 + d.steps.length * 2;
    final h = rows * cellH + 16;
    const w = 210.0;
    const left = 8.0;
    const inside = left + 40.0; // 被除数起始 x

    // 用等宽字宽的估值来定位：每个字符 cellW
    final chW = fontSize * 0.62;
    String divText = '${d.dividend}';
    final divW = divText.length * chW;

    final buf = StringBuffer();
    buf.write('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${_n(w)} ${_n(h)}" '
        'width="${_n(w)}" height="${_n(h)}" class="vert-svg">');
    buf.write('<g font-family="ui-monospace, Consolas, monospace" font-size="$fontSize" '
        'dominant-baseline="middle">');

    // 商（写在横线上方）
    buf.write('<text x="${_n(left + 18)}" y="${_n(cellH * 0.5)}" font-weight="700" '
        'fill="#1e293b">${d.quotient}</text>');

    // "厂"形：横线覆盖整个被除数，左竖向下
    final barY = cellH * 1.25;
    buf.write('<path d="M ${_n(left + 12)} ${_n(barY)} L ${_n(inside + divW + 10)} ${_n(barY)}" '
        'stroke="#1e293b" stroke-width="1.4" fill="none"/>');
    buf.write('<path d="M ${_n(left + 12)} ${_n(barY)} L ${_n(left + 12)} ${_n(cellH * 1.95)}" '
        'stroke="#1e293b" stroke-width="1.4" fill="none"/>');

    // 除数（左侧）、被除数（厂内）
    final baseY = cellH * 1.7;
    buf.write('<text x="${_n(left + 15)}" y="${_n(baseY)}">${d.divisor}</text>');
    buf.write('<text x="${_n(inside)}" y="${_n(baseY)}">$divText</text>');
    if (!d.isExact) {
      buf.write('<text x="${_n(inside + divW + 8)}" y="${_n(baseY)}" '
          'font-size="${_n(fontSize * 0.8)}" fill="#475569">……${d.remainder}</text>');
    }

    // 逐步：乘积 + 相减横线 + 余数
    var y = cellH * 2.5;
    for (final s in d.steps) {
      final pText = '${s.product}';
      final pW = pText.length * chW;
      final indent = inside + (divText.length - pText.length) * chW;
      buf.write('<text x="${_n(indent)}" y="${_n(y)}">$pText</text>');
      buf.write('<path d="M ${_n(indent - 3)} ${_n(y + cellH * 0.38)} '
          'L ${_n(indent + pW + 4)} ${_n(y + cellH * 0.38)}" stroke="#1e293b" '
          'stroke-width="1.1" fill="none"/>');
      final rText = '${s.remainder}';
      final rIndent = inside + (divText.length - rText.length) * chW;
      buf.write('<text x="${_n(rIndent)}" y="${_n(y + cellH * 0.85)}">$rText</text>');
      y += cellH * 1.15;
    }

    buf.write('</g></svg>');
    return buf.toString();
  }

  static String _esc(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');

  static String _n(double v) {
    final r = (v * 100).roundToDouble() / 100;
    final s = r.toStringAsFixed(2);
    return s.replaceAll(RegExp(r'0+$'), '').replaceAll(RegExp(r'\.$'), '');
  }
}
