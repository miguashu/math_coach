/// FigureScene → Flutter Canvas（第四个渲染器）。
///
/// 同一份 FigureScene 已经有 PDF 渲染器、Web 的 SVG 渲染器，这里是 App 用的
/// CustomPainter。**不引三方 SVG 包**：屏幕渲染走 Canvas，缩放自适应、没有
/// 字符串拼 DOM 的中间环节，也少一层依赖。
///
/// 坐标约定与 PDF 渲染器一致：
///   Canvas 是 y 向下（左下原点），数学是 y 向上，所以这里的 tf 做一次翻转。
///   圆弧因为是绕中心的旋转，翻转后 start 角必须取 -(start+sweep) 才是同一段弧。
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:math_coach/core/pt.dart';
import 'package:math_coach/geometry/dsl/figure.dart';

/// 把一个 FigureScene 画出来，尺寸自适应。
///
/// [width] 是期望宽度；高度按图形本身比例算。
/// [pad] 是给标注文字留的白，**固定 px，不随图形尺寸变化** —— 否则一个
/// 半径 3 的圆会被几倍于自身的留白挤成一团（这个坑在 PDF 版已经踩过一次）。
class FigureView extends StatelessWidget {
  final FigureScene scene;
  final double width;
  final double? maxHeight;
  final double pad;

  const FigureView({
    super.key,
    required this.scene,
    this.width = 260,
    this.maxHeight,
    this.pad = 26,
  });

  /// 算出 painter 需要的几何参数，交给 [_FigurePainter] 复用。
  _FigureMetrics metrics() {
    final b = scene.extent;
    final ew = math.max(b.w, 1.0);
    final eh = math.max(b.h, 1.0);
    var scale = (width - pad * 2) / ew;
    if (maxHeight != null) {
      final byHeight = (maxHeight! - pad * 2) / eh;
      if (byHeight < scale) scale = byHeight;
    }
    scale = scale.clamp(4.0, 26.0);
    return _FigureMetrics(scale: scale, w: ew * scale + pad * 2, h: eh * scale + pad * 2);
  }

  @override
  Widget build(BuildContext context) {
    final m = metrics();
    return SizedBox(
      width: m.w,
      height: m.h,
      child: CustomPaint(
        size: Size(m.w, m.h),
        painter: _FigurePainter(scene, m.scale, pad, m.h),
      ),
    );
  }
}

class _FigureMetrics {
  final double scale;
  final double w;
  final double h;
  const _FigureMetrics({required this.scale, required this.w, required this.h});
}

class _FigurePainter extends CustomPainter {
  final FigureScene scene;
  final double scale;
  final double pad;
  final double height;

  const _FigurePainter(this.scene, this.scale, this.pad, this.height);

  Offset tf(Pt p) => Offset(
        (p.x - scene.extent.minX) * scale + pad,
        height - ((p.y - scene.extent.minY) * scale + pad),
      );

  @override
  bool shouldRepaint(covariant _FigurePainter old) =>
      old.scene != scene || old.scale != scale || old.height != height;

  @override
  void paint(Canvas canvas, Size size) {
    const lineColor = Color(0xFF1E293B);
    const thinColor = Color(0xFF94A3B8);
    const shadeColor = Color(0xFFDBEAFE);

    double lwFor(LineStyle s) => s == LineStyle.bold
        ? 3.2
        : (s == LineStyle.thin ? 0.7 : 1.6);

    Paint strokeFor(LineStyle style, {FillStyle fill = FillStyle.none}) {
      final p = Paint()
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..strokeWidth = lwFor(style)
        ..color = style == LineStyle.thin ? thinColor : lineColor;
      return p;
    }

    /// 虚线 = 被挡住的棱/底。本机 dart:ui 没有 PathEffect，
    /// 用 computeMetrics 沿路径截短段实现；间隔与 Web 端 SVG（5/3.5）同款视觉。
    /// 曾经漏了整个虚线分支，立体图的隐藏线在 App 上全画成实线。
    void strokeDashed(Canvas canvas, Path path, Paint paint) {
      const dash = 7.0, gap = 5.0;
      for (final m in path.computeMetrics()) {
        var dist = 0.0;
        while (dist < m.length) {
          final next = math.min(dist + dash, m.length);
          canvas.drawPath(m.extractPath(dist, next), paint);
          dist = next + gap;
        }
      }
    }

    void paintFill(Path path, FillStyle fill) {
      if (fill == FillStyle.none) return;
      if (fill == FillStyle.shade) {
        canvas.drawPath(path, Paint()
          ..style = PaintingStyle.fill
          ..color = shadeColor);
      } else {
        // hatch：先画淡底，再在形状内部裁出斜线
        canvas.drawPath(path, Paint()
          ..style = PaintingStyle.fill
          ..color = const Color(0xFFF1F5F9));
        canvas.save();
        canvas.clipPath(path);
        final hp = Paint()
          ..strokeWidth = 1.2
          ..color = thinColor;
        for (double x = -size.height; x < size.width + size.height; x += 6) {
          canvas.drawLine(Offset(x, 0), Offset(x + size.height, size.height), hp);
        }
        canvas.restore();
      }
    }

    for (final shape in scene.shapes) {
      if (shape is SLine) {
        final a = tf(shape.a);
        final c = tf(shape.b);
        final p = strokeFor(shape.style);
        if (shape.style == LineStyle.dashed) {
          strokeDashed(canvas, Path()
            ..moveTo(a.dx, a.dy)
            ..lineTo(c.dx, c.dy), p);
        } else {
          canvas.drawLine(a, c, p);
        }

      } else if (shape is SPolyline) {
        final pts = shape.pts.map(tf).toList();
        if (pts.length < 2) continue;
        final path = Path()..addPolygon(pts, shape.closed);
        paintFill(path, shape.fill);
        canvas.drawPath(path, strokeFor(shape.style));

      } else if (shape is SCircle) {
        final c = tf(shape.c);
        final r = shape.r * scale;
        final path = Path()
          ..addOval(Rect.fromCircle(center: c, radius: r));
        paintFill(path, shape.fill);
        canvas.drawPath(path, strokeFor(shape.style));

      } else if (shape is SEllipse) {
        final c = tf(shape.c);
        final path = Path()..addOval(Rect.fromCenter(
          center: c,
          width: shape.rx * 2 * scale,
          height: shape.ry * 2 * scale,
        ));
        paintFill(path, shape.fill);
        final p = strokeFor(shape.style);
        if (shape.style == LineStyle.dashed) {
          strokeDashed(canvas, path, p); // 圆柱下底等被挡住的透视圆
        } else {
          canvas.drawPath(path, p);
        }

      } else if (shape is SArc) {
        final c = tf(shape.c);
        final r = shape.r * scale;
        final rect = Rect.fromCircle(center: c, radius: r);
        // 数学 CCW → Canvas 的 y 向下，必须把起终角取反才是同一段弧
        final startCanvas = -(shape.start + shape.sweep);
        final path = Path();
        if (shape.closedToCenter) {
          path.moveTo(c.dx, c.dy);
          path.arcTo(rect, startCanvas, shape.sweep, false);
          path.close();
        } else {
          path.arcTo(rect, startCanvas, shape.sweep, false);
        }
        paintFill(path, shape.fill);
        canvas.drawPath(path, strokeFor(shape.style));

      } else if (shape is SPath) {
        final path = Path();
        path.moveTo(tf(shape.start).dx, tf(shape.start).dy);
        for (final seg in shape.segs) {
          final c1 = tf(seg.c1);
          final c2 = tf(seg.c2);
          final e = tf(seg.p);
          path.cubicTo(c1.dx, c1.dy, c2.dx, c2.dy, e.dx, e.dy);
        }
        if (shape.closed) path.close();
        paintFill(path, shape.fill);
        canvas.drawPath(path, strokeFor(LineStyle.solid));

      } else if (shape is SRightAngle) {
        final at = tf(shape.at);
        final d1 = shape.dir1.unit;
        final d2 = shape.dir2.unit;
        final s = shape.size * scale;
        final p1 = Offset(at.dx + d1.x * s, at.dy - d1.y * s);
        final p3 = Offset(at.dx + d2.x * s, at.dy - d2.y * s);
        final p2 = Offset(p1.dx + d2.x * s, p1.dy - d2.y * s);
        canvas.drawLine(p1, p2, strokeFor(LineStyle.thin));
        canvas.drawLine(p2, p3, strokeFor(LineStyle.thin));
      }
    }

    // 顶点小圆点
    for (final d in scene.dots) {
      canvas.drawCircle(tf(d), 2.2, Paint()
        ..style = PaintingStyle.fill
        ..color = lineColor);
    }

    // 标注（真文本，Android 用系统字体渲染中文）
    for (final l in scene.labels) {
      if (l.text.isEmpty) continue;
      final p = tf(l.at);
      final isLen = l.kind == LabelKind.length;
      final isArea = l.kind == LabelKind.area;
      final fontSize = l.kind == LabelKind.point ? 11.0 : 11.5;
      final color = isLen
          ? const Color(0xFF1D4ED8)
          : (isArea ? const Color(0xFF0F766E) : const Color(0xFF334155));
      final tp = TextPainter(
        text: TextSpan(
          text: l.text,
          style: TextStyle(
            fontSize: fontSize,
            color: color,
            fontWeight: (isLen || isArea) ? FontWeight.w600 : FontWeight.w400,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(p.dx - tp.width / 2, p.dy - tp.height / 2));
    }
  }
}
