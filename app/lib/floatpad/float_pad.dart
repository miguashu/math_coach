/// 浮窗演算板（手机 / 平板通用）。
///
/// 形态：一个可拖拽的悬浮球，点开成演算面板，内含「计算 / 画板」两个模式。
/// 家长在孩子写作业时随手点开验算，看完收起，不离开当前页面。
///
/// 三个设计决定：
///
/// ① **刻意不做系统级悬浮窗**（SYSTEM_ALERT_WINDOW / 画中画）。
///    系统悬浮窗要额外授权，平板分屏与多任务下行为也不可控；
///    App 内浮窗已经覆盖"随时验算"的场景，且不打扰系统其它应用。
/// ② **不用手写识别**。识别错了比没有更糟 —— 家长会把识别错的数
///    当验算结果。要手算就切「画板」模式自己画。
/// ③ **平板不另做一套**。面板按最短边 >= 600 切宽布局（左输入右结果），
///    同一份代码；主界面仍锁竖屏（竖式/几何题横屏会被压扁），
///    平板竖屏下宽度也够宽布局用。
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:math_coach/calc/expression.dart';

import '../render/vertical_view.dart';
import 'scratch_canvas.dart';

class FloatPadHost extends StatefulWidget {
  const FloatPadHost({super.key});

  @override
  State<FloatPadHost> createState() => FloatPadHostState();
}

class FloatPadHostState extends State<FloatPadHost> {
  static const double _ball = 52.0;
  static const _blue = Color(0xFF2563EB);

  bool _open = false;
  Offset _pos = Offset.zero;
  bool _placed = false;
  int _tab = 0; // 0 计算 / 1 画板

  final _ctl = TextEditingController();
  String _main = '';
  List<String> _subs = const [];
  String? _error;
  PadVertical? _vertical;
  final List<(String, String)> _history = [];

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  // ── 计算 ────────────────────────────────────────────

  void _eval() {
    final src = _ctl.text.trim();
    if (src.isEmpty) {
      setState(() {
        _main = '';
        _subs = const [];
        _error = null;
        _vertical = null;
      });
      return;
    }
    try {
      final r = evaluate(src);
      final f = decimalForm(r.value);
      final subs = <String>[];
      if (f.repeating) subs.add('循环节 ${f.cycle}');
      if (!r.value.isInteger) {
        subs.add('分数 ${r.value.toFractionString()}');
        final mixed = r.value.toMixedString();
        if (mixed != r.value.toFractionString()) subs.add('带分数 $mixed');
      }
      setState(() {
        _main = f.text;
        _subs = subs;
        _error = null;
        _vertical = PadVertical.of(r);
      });
    } on CalcError catch (e) {
      setState(() {
        _main = '';
        _subs = const [];
        _error = e.message;
        _vertical = null;
      });
    }
  }

  void _press(String s) {
    _ctl.text = '${_ctl.text}$s';
    _ctl.selection = TextSelection.collapsed(offset: _ctl.text.length);
    _eval();
  }

  void _backspace() {
    final chars = _ctl.text.characters;
    if (chars.isEmpty) return;
    _ctl.text = chars.take(chars.length - 1).string;
    _ctl.selection = TextSelection.collapsed(offset: _ctl.text.length);
    _eval();
  }

  void _submit() {
    _eval();
    final src = _ctl.text.trim();
    if (_error == null && _main.isNotEmpty && src.isNotEmpty) {
      setState(() {
        _history.insert(0, (src, _main));
        if (_history.length > 12) _history.removeLast();
      });
    }
  }

  void _close() => setState(() => _open = false);

  // ── 布局 ────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final size = mq.size;
    final kb = mq.viewInsets.bottom;
    if (!_placed) {
      // 默认停在底部导航上方、靠右：不挡路，又一点就到
      _pos = Offset(size.width - _ball - 14, size.height - _ball - 118);
      _placed = true;
    }
    final wide = size.shortestSide >= 600;
    final pw = wide ? math.min(580.0, size.width * 0.62) : math.min(380.0, size.width - 24);
    final ph = math.min(wide ? 620.0 : 560.0, math.max(240.0, size.height - kb - 24));

    return LayoutBuilder(
      builder: (context, box) {
        final w = box.biggest.width;
        final h = box.biggest.height;
        final cx = _pos.dx.clamp(8.0, math.max(8.0, w - _ball - 8)).toDouble();
        final cy = _pos.dy.clamp(8.0, math.max(8.0, h - _ball - 8)).toDouble();
        return Stack(
          children: [
            if (!_open)
              Positioned(left: cx, top: cy, child: _ballWidget(w, h)),
            if (_open) ...[
              // 面板外点一下收起（浮窗的常规交互）
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: _close,
                ),
              ),
              Positioned(
                right: 12,
                bottom: 12 + kb, // 键盘弹起时整个面板抬到键盘上方
                child: _panel(pw, ph, wide),
              ),
            ],
          ],
        );
      },
    );
  }

  Widget _ballWidget(double w, double h) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onPanUpdate: (d) => setState(() {
        _pos = Offset(_pos.dx + d.delta.dx, _pos.dy + d.delta.dy);
      }),
      onTap: () => setState(() => _open = true),
      child: Container(
        width: _ball,
        height: _ball,
        decoration: BoxDecoration(
          color: _blue,
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.26),
              blurRadius: 10,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        child: const Icon(Icons.calculate_outlined, color: Colors.white, size: 26),
      ),
    );
  }

  Widget _panel(double pw, double ph, bool wide) {
    return Material(
      elevation: 16,
      borderRadius: BorderRadius.circular(18),
      color: Colors.white,
      clipBehavior: Clip.antiAlias,
      child: Container(
        width: pw,
        height: ph,
        padding: const EdgeInsets.fromLTRB(14, 8, 14, 12),
        child: Column(
          children: [
            _header(),
            const SizedBox(height: 6),
            Expanded(
              child: _tab == 0 ? _calcBody(wide) : const ScratchBoard(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _header() {
    return Row(
      children: [
        const Text(
          '演算板',
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w700,
            color: Color(0xFF0F172A),
          ),
        ),
        const SizedBox(width: 10),
        SizedBox(
          height: 34,
          child: SegmentedButton<int>(
            segments: const [
              ButtonSegment(
                value: 0,
                icon: Icon(Icons.functions, size: 15),
                label: Text('计算', style: TextStyle(fontSize: 12)),
              ),
              ButtonSegment(
                value: 1,
                icon: Icon(Icons.draw_outlined, size: 15),
                label: Text('画板', style: TextStyle(fontSize: 12)),
              ),
            ],
            selected: {_tab},
            onSelectionChanged: (s) => setState(() => _tab = s.first),
            showSelectedIcon: false,
            style: ButtonStyle(
              visualDensity: VisualDensity.compact,
              padding: WidgetStateProperty.all(const EdgeInsets.symmetric(horizontal: 10)),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          ),
        ),
        const Spacer(),
        IconButton(
          icon: const Icon(Icons.close, size: 20),
          onPressed: _close,
          visualDensity: VisualDensity.compact,
          tooltip: '收起',
          color: const Color(0xFF64748B),
        ),
      ],
    );
  }

  // ── 计算模式 ────────────────────────────────────────

  Widget _calcBody(bool wide) {
    final input = _inputRow();
    final keypad = _keypad();
    final result = _resultBlock();
    final vertical = _verticalBlock();
    final history = _historyRow();

    if (!wide) {
      return Column(
        children: [
          input,
          result,
          const SizedBox(height: 4),
          Expanded(
            child: SingleChildScrollView(child: vertical),
          ),
          keypad,
          history,
        ],
      );
    }
    // 平板：左边输入+键盘，右边结果+竖式+历史
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          flex: 5,
          child: Column(
            children: [input, result, const Spacer(), keypad],
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          flex: 6,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [vertical, const SizedBox(height: 8), history],
            ),
          ),
        ),
      ],
    );
  }

  Widget _inputRow() {
    return Row(
      children: [
        Expanded(
          child: SizedBox(
            height: 46,
            child: TextField(
              controller: _ctl,
              onChanged: (_) => _eval(),
              onSubmitted: (_) => _submit(),
              textInputAction: TextInputAction.done,
              style: const TextStyle(fontSize: 18, color: Color(0xFF0F172A)),
              decoration: InputDecoration(
                isDense: true,
                filled: true,
                fillColor: const Color(0xFFF1F5F9),
                hintText: '输入算式，如 3.5×2.4、58÷7、2又1/3',
                hintStyle: const TextStyle(fontSize: 13, color: Color(0xFF94A3B8)),
                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
        ),
        const SizedBox(width: 6),
        IconButton(
          icon: const Icon(Icons.backspace_outlined, size: 20),
          onPressed: _backspace,
          visualDensity: VisualDensity.compact,
          tooltip: '退格',
          color: const Color(0xFF475569),
        ),
      ],
    );
  }

  Widget _resultBlock() {
    if (_error != null) {
      return Container(
        width: double.infinity,
        margin: const EdgeInsets.only(top: 6),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: const Color(0xFFFEF2F2),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text(
          _error!,
          style: const TextStyle(fontSize: 13, color: Color(0xFFB91C1C)),
        ),
      );
    }
    if (_main.isEmpty) {
      return Container(
        width: double.infinity,
        margin: const EdgeInsets.only(top: 6),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: const Text(
          '输入即算，= 计入历史；一步算式自动出竖式',
          style: TextStyle(fontSize: 12, color: Color(0xFF94A3B8)),
        ),
      );
    }
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _main,
            style: const TextStyle(
              fontSize: 30,
              fontWeight: FontWeight.w800,
              color: Color(0xFF0F172A),
            ),
          ),
          for (final s in _subs)
            Text(
              s,
              style: const TextStyle(fontSize: 13, color: Color(0xFF475569)),
            ),
        ],
      ),
    );
  }

  Widget _verticalBlock() {
    final v = _vertical;
    if (v == null) return const SizedBox.shrink();
    final steps = v.layout?.steps ?? const <String>[];
    final divNote = v.division?.display;
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: v.layout != null
                  ? VerticalView(layout: v.layout!)
                  : LongDivisionView(d: v.division!),
            ),
          ),
          if (divNote != null) ...[
            const SizedBox(height: 6),
            Text(
              divNote,
              style: const TextStyle(fontSize: 13, color: Color(0xFF475569)),
            ),
          ],
          for (final s in steps)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                '· $s',
                style: const TextStyle(fontSize: 12, color: Color(0xFF64748B)),
              ),
            ),
        ],
      ),
    );
  }

  static const _keys = [
    ['7', '8', '9', '÷'],
    ['4', '5', '6', '×'],
    ['1', '2', '3', '−'],
    ['0', '.', '=', '+'],
    ['(', ')', '又', '%'],
  ];

  Widget _keypad() {
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Column(
        children: [
          for (final row in _keys)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                children: [
                  for (final k in row) Expanded(child: _key(k)),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _key(String label) {
    final isEq = label == '=';
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 3),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => isEq ? _submit() : _press(label),
        child: Container(
          height: 38,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: isEq ? _blue : const Color(0xFFF1F5F9),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w600,
              color: isEq ? Colors.white : const Color(0xFF334155),
            ),
          ),
        ),
      ),
    );
  }

  Widget _historyRow() {
    if (_history.isEmpty) return const SizedBox.shrink();
    return SizedBox(
      height: 32,
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: [
          for (final (src, res) in _history)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: ActionChip(
                label: Text('$src = $res', style: const TextStyle(fontSize: 12)),
                visualDensity: VisualDensity.compact,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                backgroundColor: const Color(0xFFEFF6FF),
                side: const BorderSide(color: Color(0xFFDBEAFE)),
                onPressed: () {
                  _ctl.text = src;
                  _ctl.selection = TextSelection.collapsed(offset: src.length);
                  _eval();
                },
              ),
            ),
        ],
      ),
    );
  }
}
