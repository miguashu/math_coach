/// FigureScene → SVG 字符串。
///
/// 这是方案里的第三个渲染器（构造 GIF：PDF 矢量 + 屏幕 + Web），
/// 消费的是同一份 FigureScene —— 答"组织了哪些点线弧"的部分本地做，
/// 只是最后落到不同的绘制后端。
///
/// 为什么屏幕显示不用 Canvas 而用 SVG：
/// SVG 是 DOM 节点，浏览器自适应缩放不糊、打印也不糊，
/// 而且可以直接塞进 innerHTML，不用写一行屏幕端绘制代码。
library;

import 'dart:math' as math;

import '../../core/pt.dart';
import '../dsl/figure.dart';

class FigureSvgRenderer {
  /// 基础线宽（px）。粗线 2 倍、细线 0.45 倍。
  final double baseLineWidth;

  const FigureSvgRenderer({this.baseLineWidth = 1.6});

  /// 把 FigureScene 渲染成独立的 SVG 文档字符串。
  ///
  /// [idPrefix] 用于避免同页多个图形时 pattern id 冲突。
  String render(FigureScene scene, {double widthPx = 240, String idPrefix = 'f'}) {
    final b = scene.extent;
    const pad = 26.0; // px，给标注文字留白（固定值，不随图形尺寸变化）
    final ew = math.max(b.w, 1.0);
    final eh = math.max(b.h, 1.0);
    var scale = (widthPx - pad * 2) / ew;
    scale = scale.clamp(4.0, 26.0);

    final w = ew * scale + pad * 2;
    final h = eh * scale + pad * 2;

    // 数学坐标 → SVG：SVG 的 y 向下，数学 y 向上，所以这里翻 Dyn一次
    Pt tf(Pt p) => Pt((p.x - b.minX) * scale + pad, h - ((p.y - b.minY) * scale + pad));

    final buf = StringBuffer();
    buf.write(
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${_n(w)} ${_n(h)}" '
        'width="${_n(w)}" height="${_n(h)}">');
    buf.write('<defs><pattern id="$idPrefix-hatch" width="6" height="6" '
        'patternUnits="userSpaceOnUse" patternTransform="rotate(45)">'
        '<line x1="0" y1="0" x2="0" y2="6" stroke="#94a3b8" stroke-width="1.2"/>'
        '</pattern></defs>');
    buf.write('<g fill="none" stroke-linecap="round" stroke-linejoin="round">');

    double lwFor(LineStyle s) => s == LineStyle.bold
        ? baseLineWidth * 2
        : (s == LineStyle.thin ? baseLineWidth * 0.42 : baseLineWidth);

    String paintFor(LineStyle style, FillStyle fill) {
      final dash = style == LineStyle.dashed ? ' stroke-dasharray="5 3.5"' : '';
      final fillAttr = fill == FillStyle.none
          ? ' fill="none"'
          : (fill == FillStyle.hatch ? ' fill="url(#$idPrefix-hatch)"' : ' fill="#dbeafe"');
      final strokeColor = style == LineStyle.thin ? '#94a3b8' : '#1e293b';
      return '$fillAttr stroke="$strokeColor" stroke-width="${_n(lwFor(style))}"$dash';
    }

    for (final shape in scene.shapes) {
      if (shape is SLine) {
        final a = tf(shape.a);
        final c = tf(shape.b);
        buf.write('<line x1="${_n(a.x)}" y1="${_n(a.y)}" x2="${_n(c.x)}" y2="${_n(c.y)}" '
            '${paintFor(shape.style, FillStyle.none)}/>');

      } else if (shape is SPolyline) {
        final pts = shape.pts.map(tf).toList();
        final d = StringBuffer('M ${_n(pts.first.x)} ${_n(pts.first.y)}');
        for (var i = 1; i < pts.length; i++) {
          d.write(' L ${_n(pts[i].x)} ${_n(pts[i].y)}');
        }
        if (shape.closed) d.write(' Z');
        buf.write('<path d="$d" ${paintFor(shape.style, shape.fill)}/>');

      } else if (shape is SCircle) {
        final c = tf(shape.c);
        buf.write('<circle cx="${_n(c.x)}" cy="${_n(c.y)}" r="${_n(shape.r * scale)}" '
            '${paintFor(shape.style, shape.fill)}/>');

      } else if (shape is SEllipse) {
        final c = tf(shape.c);
        buf.write('<ellipse cx="${_n(c.x)}" cy="${_n(c.y)}" rx="${_n(shape.rx * scale)}" '
            'ry="${_n(shape.ry * scale)}" ${paintFor(shape.style, shape.fill)}/>');

      } else if (shape is SArc) {
        final c = tf(shape.c);
        final r = shape.r * scale;
        final sweep = shape.sweep;
        final start = shape.start;
        final end = start + sweep;
        final p0 = tf(shape.c + Pt(shape.r * math.cos(start), shape.r * math.sin(start)));
        final p1 = tf(shape.c + Pt(shape.r * math.cos(end), shape.r * math.sin(end)));
        // tf 已经翻转过 y，视觉方向与数学方向一致（CCW）。
        // SVG 的 sweep-flag=1 表示屏幕正角方向（顺时针），所以 CCW 取 0。
        final sweepFlag = sweep >= 0 ? 0 : 1;
        final largeArc = sweep.abs() > math.pi ? 1 : 0;
        final open =
            'M ${_n(p0.x)} ${_n(p0.y)} A ${_n(r)} ${_n(r)} 0 $largeArc $sweepFlag ${_n(p1.x)} ${_n(p1.y)}';
        final d = shape.closedToCenter
            ? '$open L ${_n(c.x)} ${_n(c.y)} Z'
            : open;
        buf.write('<path d="$d" ${paintFor(shape.style, shape.fill)}/>');

      } else if (shape is SPath) {
        final s0 = tf(shape.start);
        final d = StringBuffer('M ${_n(s0.x)} ${_n(s0.y)}');
        for (final seg in shape.segs) {
          final c1 = tf(seg.c1);
          final c2 = tf(seg.c2);
          final p = tf(seg.p);
          d.write(' C ${_n(c1.x)} ${_n(c1.y)} ${_n(c2.x)} ${_n(c2.y)} '
              '${_n(p.x)} ${_n(p.y)}');
        }
        if (shape.closed) d.write(' Z');
        buf.write('<path d="$d" ${paintFor(LineStyle.solid, shape.fill)}/>');

      } else if (shape is SRightAngle) {
        final at = tf(shape.at);
        final d1 = shape.dir1.unit;
        final d2 = shape.dir2.unit;
        final s = shape.size * scale;
        final p1 = Pt(at.x + d1.x * s, at.y - d1.y * s);
        final p3 = Pt(at.x + d2.x * s, at.y - d2.y * s);
        final p2 = Pt(p1.x + d2.x * s, p1.y - d2.y * s);
        buf.write('<polyline points="${_n(p1.x)},${_n(p1.y)} ${_n(p2.x)},${_n(p2.y)} '
            '${_n(p3.x)},${_n(p3.y)}" ${paintFor(LineStyle.solid, FillStyle.none)} '
            'stroke-width="${_n(baseLineWidth * 0.8)}"/>');
      }
    }

    // 顶点小圆点
    for (final d in scene.dots) {
      final p = tf(d);
      buf.write('<circle cx="${_n(p.x)}" cy="${_n(p.y)}" r="2.2" fill="#1e293b"/>');
    }

    // 标注（真文本，浏览器负责字体，中文不会丢）
    for (final l in scene.labels) {
      if (l.text.isEmpty) continue;
      final p = tf(l.at);
      final isLen = l.kind == LabelKind.length;
      final size = l.kind == LabelKind.point ? 11.0 : 11.5;
      final color = isLen ? '#1d4ed8' : (l.kind == LabelKind.area ? '#0f766e' : '#334155');
      final weight = (isLen || l.kind == LabelKind.area) ? '600' : '400';
      buf.write('<text x="${_n(p.x)}" y="${_n(p.y)}" text-anchor="middle" '
          'dominant-baseline="middle" font-size="$size" fill="$color" '
          'font-weight="$weight">${_esc(l.text)}</text>');
    }

    buf.write('</g></svg>');
    return buf.toString();
  }

  static String _esc(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;');

  static String _n(double v) {
    final r = (v * 100).roundToDouble() / 100;
    final s = r.toStringAsFixed(2);
    return s.replaceAll(RegExp(r'0+$'), '').replaceAll(RegExp(r'\.$'), '');
  }
}
