/// 画板：手指/触控笔随手画，给家长在浮窗里打草稿、圈重点。
///
/// 刻意不做手写识别 —— 识别是另一个量级的工程，且识别错了比没有更糟
/// （家长会把错误结果当验算结果）。这一块就是一块干净的电子草稿纸：
/// 能画、能换色、能擦、能撤销，画完拍个截图留证即可。
library;

import 'package:flutter/material.dart';

const _penWidth = 2.6;
const _eraserWidth = 18.0;
const _eraserColor = Color(0xFFFFFFFF);

class ScratchBoard extends StatefulWidget {
  const ScratchBoard({super.key});

  @override
  State<ScratchBoard> createState() => _ScratchBoardState();
}

class _ScratchBoardState extends State<ScratchBoard> {
  /// 每条笔画是一串点；null 表示提笔（笔画之间断开）。
  final List<List<Offset?>> _strokes = [];

  Color _color = const Color(0xFF1E293B);
  bool _eraser = false;

  static const _palette = [
    Color(0xFF1E293B), // 墨黑
    Color(0xFFDC2626), // 红
    Color(0xFF2563EB), // 蓝
    Color(0xFF16A34A), // 绿
  ];

  void _undo() {
    setState(() {
      if (_strokes.isNotEmpty) _strokes.removeLast();
    });
  }

  void _clear() => setState(_strokes.clear);

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _toolbar(),
        const SizedBox(height: 8),
        Expanded(child: _canvas()),
      ],
    );
  }

  Widget _toolbar() {
    return Row(
      children: [
        for (final c in _palette)
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => setState(() {
              _color = c;
              _eraser = false;
            }),
            child: Container(
              width: 26,
              height: 26,
              margin: const EdgeInsets.only(right: 8),
              decoration: BoxDecoration(
                color: c,
                shape: BoxShape.circle,
                border: Border.all(
                  color: !_eraser && _color == c
                      ? const Color(0xFF2563EB)
                      : const Color(0xFFE2E8F0),
                  width: !_eraser && _color == c ? 2.5 : 1.5,
                ),
              ),
            ),
          ),
        const Spacer(),
        _toolButton(
          icon: Icons.undo,
          tip: '撤销一笔',
          onTap: _undo,
          active: false,
        ),
        const SizedBox(width: 6),
        _toolButton(
          icon: Icons.auto_delete_outlined,
          tip: '橡皮',
          onTap: () => setState(() => _eraser = !_eraser),
          active: _eraser,
        ),
        const SizedBox(width: 6),
        _toolButton(
          icon: Icons.delete_outline,
          tip: '清空',
          onTap: _clear,
          active: false,
        ),
      ],
    );
  }

  Widget _toolButton({
    required IconData icon,
    required String tip,
    required VoidCallback onTap,
    required bool active,
  }) {
    return Tooltip(
      message: tip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          width: 34,
          height: 30,
          decoration: BoxDecoration(
            color: active ? const Color(0xFFDBEAFE) : const Color(0xFFF1F5F9),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(
            icon,
            size: 17,
            color: active ? const Color(0xFF2563EB) : const Color(0xFF475569),
          ),
        ),
      ),
    );
  }

  Widget _canvas() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      clipBehavior: Clip.antiAlias,
      child: GestureDetector(
        onPanStart: (d) => setState(() => _strokes.add([d.localPosition])),
        onPanUpdate: (d) =>
            setState(() => _strokes.last.add(d.localPosition)),
        child: CustomPaint(
          painter: _BoardPainter(_strokes, _eraser ? _eraserColor : _color),
          size: Size.infinite,
        ),
      ),
    );
  }
}

class _BoardPainter extends CustomPainter {
  final List<List<Offset?>> strokes;
  final Color color;
  const _BoardPainter(this.strokes, this.color);

  @override
  void paint(Canvas canvas, Size size) {
    // 橡皮直接画白色：背景就是白的，比 BlendMode.clear 少一层合成，也不会
    // 在透明区域留下"擦不掉"的洞。
    final isEraser = color == _eraserColor;
    final paint = Paint()
      ..color = color
      ..strokeWidth = isEraser ? _eraserWidth : _penWidth
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;

    for (final stroke in strokes) {
      if (stroke.isEmpty) continue;
      final path = Path();
      var started = false;
      for (final p in stroke) {
        if (p == null) {
          started = false;
          continue;
        }
        if (!started) {
          path.moveTo(p.dx, p.dy);
          started = true;
        } else {
          path.lineTo(p.dx, p.dy);
        }
      }
      canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _BoardPainter old) =>
      // 笔画是原地追加的（同一个 List 实例），按内容比较没有意义，
      // 这块画布很小，直接重画。
      true;
}
