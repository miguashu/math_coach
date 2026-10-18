import 'dart:math' as math;

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../core/pt.dart';
import '../dsl/figure.dart';

/// PDF 矢量渲染器：把 FigureScene 用 PdfGraphics 画成真矢量。
///
/// 为什么必须写第二个渲染器（而不是把屏幕截图塞进 PDF）：
/// 截图在 A4 打印放大会糊；矢量路径无论放大多少倍都清晰，而且体积小。
/// 屏幕端用 CustomPainter，导出端用这里，两者消费的是同一份 FigureScene。
class FigurePdfRenderer {
  final PdfFont font;
  final PdfFont fontBold;

  /// 线条颜色 / 线宽（单位：数学单位，会随缩放换算）。
  final PdfColor lineColor;
  final PdfColor accentColor;
  final PdfColor shadeColor;
  final double baseLineWidth;

  const FigurePdfRenderer({
    required this.font,
    required this.fontBold,
    this.lineColor = PdfColors.black,
    this.accentColor = PdfColors.blue800,
    this.shadeColor = PdfColors.blue50,
    this.baseLineWidth = 0.9,
  });

  /// 渲染成一个可放进 pw.Document 的 Widget。
  ///
  /// [widthPt] 为期望宽度（PDF 点），高度按图形比例自适应。
  ///
  /// 缩放约定：数学单位是"厘米"，标注文字是 pt。padding 必须用 pt 固定，
  /// 不能按数学单位算 —— 否则小图形（如 r=3 的圆，extent 只有 6 单位宽）
  /// 会被 52 单位的 padding 主导，scale 被压得极小，图形缩成一小团。
  pw.Widget render(FigureScene scene, {required double widthPt}) {
    final b = scene.extent;
    const padPt = 30.0; // 给标注文字的留白（pt，固定）
    final ew = math.max(b.w, 1.0);
    final eh = math.max(b.h, 1.0);
    var scale = (widthPt - padPt * 2) / ew;
    // 防走极端：太小看不清，太大在小图形上显得失真
    scale = scale.clamp(5.0, 30.0);
    final drawW = ew * scale + padPt * 2;
    final heightPt = eh * scale + padPt * 2;

    return pw.SizedBox(
      width: drawW,
      height: heightPt,
      child: pw.CustomPaint(
        size: PdfPoint(drawW, heightPt),
        painter: (PdfGraphics g, PdfPoint size) {
          // pw.CustomPaint 的 PdfGraphics 坐标系是 y 向上（左下原点），
          // 与数学坐标方向一致 —— 直接映射，不要翻转（翻转会导致图形上下镜像）。
          Pt tf(Pt p) => Pt(
              (p.x - b.minX) * scale + padPt,
              (p.y - b.minY) * scale + padPt);

          void setLine(LineStyle style) {
            g.setStrokeColor(style == LineStyle.thin ? PdfColors.grey400 : lineColor);
            g.setLineWidth(style == LineStyle.bold
                ? baseLineWidth * 2
                : (style == LineStyle.thin ? baseLineWidth * 0.45 : baseLineWidth));
            // 虚线 = 被挡住的棱/底（长方体隐藏棱、圆柱下底）。
            // 与 Web 端 SVG 的 5/3.5 同款视觉；漏了这个分支打印卷子上
            // 隐藏线会变实线，孩子分不清哪条棱在后面。
            if (style == LineStyle.dashed) {
              g.setLineDashPattern(const <num>[5, 3.5], 0);
            } else {
              g.setLineDashPattern(const <num>[], 0);
            }
          }

          void applyFill(FillStyle fill) {
            if (fill == FillStyle.none) {
              g.setFillColor(const PdfColor(0, 0, 0, 0));
            } else {
              g.setFillColor(fill == FillStyle.hatch ? PdfColors.grey300 : shadeColor);
            }
          }

          for (final shape in scene.shapes) {
            if (shape is SLine) {
              final a = tf(shape.a);
              final c = tf(shape.b);
              setLine(shape.style);
              g.drawLine(a.x, a.y, c.x, c.y);
              g.strokePath(); // pdf 包的 drawLine 不自动描边
            } else if (shape is SPolyline) {
              if (shape.pts.length < 2) continue;
              final first = tf(shape.pts.first);
              setLine(shape.style);
              applyFill(shape.fill);
              g.moveTo(first.x, first.y);
              for (var i = 1; i < shape.pts.length; i++) {
                final p = tf(shape.pts[i]);
                g.lineTo(p.x, p.y);
              }
              if (shape.closed) {
                g.closePath();
                if (shape.fill != FillStyle.none) {
                  g.fillPath();
                  // 填充完再描一次边
                  g.moveTo(first.x, first.y);
                  for (var i = 1; i < shape.pts.length; i++) {
                    final p = tf(shape.pts[i]);
                    g.lineTo(p.x, p.y);
                  }
                  g.closePath();
                }
                g.strokePath();
              } else {
                g.strokePath();
              }

            } else if (shape is SCircle) {
              final c = tf(shape.c);
              setLine(shape.style);
              applyFill(shape.fill);
              g.drawEllipse(c.x, c.y, shape.r * scale, shape.r * scale);
              if (shape.fill != FillStyle.none) g.fillPath();
              g.strokePath();

            } else if (shape is SEllipse) {
              final c = tf(shape.c);
              setLine(shape.style);
              applyFill(shape.fill);
              g.drawEllipse(c.x, c.y, shape.rx * scale, shape.ry * scale);
              if (shape.fill != FillStyle.none) g.fillPath();
              g.strokePath();

            } else if (shape is SArc) {
              final c = tf(shape.c);
              setLine(shape.style);
              applyFill(shape.fill);
              // painter 坐标系 y-up，与数学坐标同向，角度直接使用
              final r = shape.r * scale;
              final startPdf = shape.start;
              final endPdf = shape.start + shape.sweep;
              final p0 = PdfPoint(c.x + r * math.cos(startPdf), c.y + r * math.sin(startPdf));
              g.moveTo(p0.x, p0.y);
              _arcTo(g, c, r, startPdf, endPdf);
              if (shape.closedToCenter) {
                g.lineTo(c.x, c.y);
                g.closePath();
                if (shape.fill != FillStyle.none) g.fillPath();
                g.strokePath();
              } else {
                g.strokePath();
              }

            } else if (shape is SPath) {
              final s = tf(shape.start);
              setLine(LineStyle.solid);
              applyFill(shape.fill);
              g.moveTo(s.x, s.y);
              for (final seg in shape.segs) {
                final c1 = tf(seg.c1);
                final c2 = tf(seg.c2);
                final p = tf(seg.p);
                g.curveTo(c1.x, c1.y, c2.x, c2.y, p.x, p.y);
              }
              if (shape.closed) {
                g.closePath();
                if (shape.fill != FillStyle.none) g.fillPath();
                g.strokePath();
              } else {
                g.strokePath();
              }

            } else if (shape is SRightAngle) {
              final at = tf(shape.at);
              final d1 = shape.dir1.unit;
              final d2 = shape.dir2.unit;
              final s = shape.size * scale;
              final p1 = PdfPoint(at.x + d1.x * s, at.y + d1.y * s);
              final p3 = PdfPoint(at.x + d2.x * s, at.y + d2.y * s);
              final p2 = PdfPoint(p1.x + (d2.x * s), p1.y + (d2.y * s));
              g.setStrokeColor(lineColor);
              g.setLineWidth(baseLineWidth * 0.8);
              g.drawLine(p1.x, p1.y, p2.x, p2.y);
              g.drawLine(p2.x, p2.y, p3.x, p3.y);
              g.strokePath();
            }
          }

          // 顶点小圆点
          g.setFillColor(lineColor);
          for (final d in scene.dots) {
            final p = tf(d);
            g.drawEllipse(p.x, p.y, 1.6, 1.6);
            g.fillPath();
          }

          // 标注文字：用真文本（PDF 内嵌字体），中文不会丢
          for (final l in scene.labels) {
            if (l.text.isEmpty) continue;
            final p = tf(l.at);
            final f = (l.kind == LabelKind.length || l.kind == LabelKind.area) ? fontBold : font;
            final size = l.kind == LabelKind.point ? 9.0 : 8.0;
            final metrics = f.stringMetrics(l.text) * size;
            g.setFont(f, size);
            g.setFillColor(l.kind == LabelKind.length ? accentColor : lineColor);
            g.drawString(f, size, l.text, p.x - metrics.width / 2, p.y - size * 0.35);
          }
        },
      ),
    );
  }

  /// 用多段贝塞尔逼近圆弧（PDF 没有原生 arc 指令）。
  void _arcTo(PdfGraphics g, Pt c, double r, double startPdf, double endPdf) {
    var sweep = endPdf - startPdf;
    // 归一化到 (0, 2π)
    while (sweep < 0) {
      sweep += 2 * math.pi;
    }
    while (sweep > 2 * math.pi) {
      sweep -= 2 * math.pi;
    }
    final segs = math.max(2, (sweep / (math.pi / 16)).ceil());
    final step = sweep / segs;
    for (var i = 1; i <= segs; i++) {
      final a = startPdf + step * i;
      final x = c.x + r * math.cos(a);
      final y = c.y + r * math.sin(a);
      g.lineTo(x, y);
    }
  }
}
